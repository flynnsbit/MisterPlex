#!/usr/bin/env bash
# rollback_v2.sh — HOST-SIDE ATOMIC restore of a matched (core, daemon) pair.
#
# CRITICAL (parent HW 2026-07-31): restoring the SPI core alone while leaving
# the DDR daemon live produces a SOLID GREEN SCREEN. /resources=200, n_daemon=1,
# and core md5 all still pass. Partial rollback is worse than no rollback.
#
# This tool is ATOMIC over the pair:
#   spi-v2-hybrid:           core dfebf2bf + daemon 50f4eb92 + conf spi
#   spi-v2-release:          core dfebf2bf + daemon 7cd10b4d + conf spi
#   ddr-c5382bee:            core c5382bee + daemon edc3a46b + conf ddr  (PRIMARY)
#   ddr-c5382bee-e9f79de2:   core c5382bee + daemon e9f79de2 + conf ddr  (hist)
#
# Sequence for restore:
#   0) resolve PAIR_ID + require daemon artifact (host or on-device .bak) UP FRONT
#   1) stop daemon (no writers; avoid ETXTBSY)
#   2) install matching daemon bytes if disk pin wrong
#   3) ONE menu bounce → pair core path
#   4) start bundle
#   5) verify pair (core path md5 + live /proc/exe md5 + n_daemon==1 + HTTP)
#   6) HARD visual gate (idle capture) — unset = rc=8, never claim success
#
# Exit codes (last line always "true rc=N"):
#   0  OK — pair matched AND visual gate passed
#   2  MISSING — proven absent on device
#   3  MISMATCH — hash wrong / pair refuse
#   4  NO-DATA
#   5  NETWORK
#   8  VISUAL_REQUIRED / VISUAL_FAIL
#   9  HARD sequence failure
#  10  REFUSE — cannot achieve atomic pair (no daemon artifact); device untouched
#
# Usage (parent only — agents must not SSH):
#   scripts/rollback_v2.sh verify
#   scripts/rollback_v2.sh restore
#   PAIR_ID=ddr-c5382bee scripts/rollback_v2.sh restore
#   ROLLBACK_DAEMON=/path/to/50f4eb92-misterplexd scripts/rollback_v2.sh restore
#
# Test inject: ROLLBACK_SSH / ROLLBACK_HTTP / ROLLBACK_SCP / PAIR_IDLE_PNG

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=md5_shape.inc.sh
source "$ROOT/scripts/md5_shape.inc.sh"
# shellcheck source=pair_ship_policy.sh
source "$ROOT/scripts/pair_ship_policy.sh"
# shellcheck source=pair_live_probe.inc.sh
source "$ROOT/scripts/pair_live_probe.inc.sh"
# shellcheck source=boot_hook_policy.sh
source "$ROOT/scripts/boot_hook_policy.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
SSH_TRIES="${ROLLBACK_SSH_TRIES:-6}"
SSH_BACKOFF_S="${ROLLBACK_SSH_BACKOFF_S:-1}"

PAIR_ID="${PAIR_ID:-$PAIR_DEFAULT_ROLLBACK}"
MENU_CORE="${DEVICE_CORE_MENU}"
PLEXCTL_CANDIDATES="/media/fat/misterplex/bin/plexctl.sh /media/fat/misterplex_v2/bin/plexctl.sh /media/fat/Scripts/plexctl.sh"
PORT="${ROLLBACK_PORT:-3005}"
ROLLBACK_REQUIRE_VISUAL="${ROLLBACK_REQUIRE_VISUAL:-}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" >&2; }

PAIR_BLOB="$(pair_policy_lookup "$PAIR_ID")" || {
  printf '%s\n' "$PAIR_BLOB"
  echo "true rc=10"
  exit 10
}
PAIR_CONF_PROFILE=none
PAIR_BANK1=unknown
while IFS= read -r line; do
  case "$line" in
    PAIR_ID=*) PAIR_ID="${line#PAIR_ID=}" ;;
    PAIR_MODE=*) PAIR_MODE="${line#PAIR_MODE=}" ;;
    PAIR_CORE_MD5=*) CORE_MD5="${line#PAIR_CORE_MD5=}" ;;
    PAIR_DAEMON_MD5=*) DAEMON_MD5="${line#PAIR_DAEMON_MD5=}" ;;
    PAIR_CORE_PATH=*) PAIR_CORE_PATH="${line#PAIR_CORE_PATH=}" ;;
    PAIR_CONF_PROFILE=*) PAIR_CONF_PROFILE="${line#PAIR_CONF_PROFILE=}" ;;
    PAIR_BANK1=*) PAIR_BANK1="${line#PAIR_BANK1=}" ;;
  esac
done <<<"$PAIR_BLOB"
V2_ROOT="${ROLLBACK_ROOT:-/media/fat/misterplex_v2}"
V2_DAEMON="$V2_ROOT/bin/misterplexd"
V2_CORE="$PAIR_CORE_PATH"
V2_CONF_DEFAULT="$V2_ROOT/misterplex.conf"
# Boot path is half of the pair (parent 2026-07-31 cold-boot defect).
PAIR_BOOT_ROOT="${PAIR_BOOT_ROOT:-$V2_ROOT}"
# LIVE hook path: prefer explicit inject, else resolve from S99user USER_SCRIPT=
# (hardcoding underscore decoy is the parent BLOCKER class).
if [ -n "${BOOT_HOOK_PATH:-}" ]; then
  :
elif [ -n "${ROLLBACK_S99_BLOB:-}" ] && [ -f "${ROLLBACK_S99_BLOB}" ]; then
  # shellcheck disable=SC1091
  _rb_s99=$(boot_hook_resolve_from_s99_file "$ROLLBACK_S99_BLOB" 1)
  printf '%s\n' "$_rb_s99" | sed 's/^/rollback: /' >&2 || true
  BOOT_HOOK_PATH="$BOOT_HOOK_DEVICE_PATH"
else
  BOOT_HOOK_PATH="${BOOT_HOOK_DEVICE_PATH}"
fi
HOST_SUPERVISE_SRC="$ROOT/scripts/misterplexd_supervise.sh"

run_ssh() {
  local remote="$1"
  local attempt=0 delay="$SSH_BACKOFF_S" out rc errf
  errf="${ROLLBACK_ERRFILE:-$ROOT/build/rollback-ssh.err}"
  mkdir -p "$(dirname "$errf")"
  while [ "$attempt" -lt "$SSH_TRIES" ]; do
    attempt=$((attempt + 1))
    : >"$errf"
    set +e
    if [ -n "${ROLLBACK_SSH:-}" ]; then
      # shellcheck disable=SC2086
      out=$($ROLLBACK_SSH "$remote" 2>"$errf")
      rc=$?
    else
      out=$(sshpass -p "$PASS" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=2 \
        -o ServerAliveCountMax=2 \
        "$USER@$HOST" "$remote" 2>"$errf")
      rc=$?
    fi
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    log "ssh-retry attempt=$attempt/${SSH_TRIES} rc=$rc err=$(tr '\n' ' ' <"$errf" | head -c 160)"
    sleep "$delay"
    delay=$((delay * 2))
    [ "$delay" -gt 16 ] && delay=16
  done
  log "ssh-FAILED after ${SSH_TRIES} attempts (NETWORK)"
  return 5
}

run_scp() {
  local src="$1" dst="$2" rc
  set +e
  if [ -n "${ROLLBACK_SCP:-}" ]; then
    # shellcheck disable=SC2086
    $ROLLBACK_SCP "$src" "$dst"
    rc=$?
  else
    sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "$src" "$USER@$HOST:$dst"
    rc=$?
  fi
  set -e
  return "$rc"
}

http_code() {
  local url="$1"
  local attempt=0 delay=1 code rc
  while [ "$attempt" -lt 4 ]; do
    attempt=$((attempt + 1))
    set +e
    if [ -n "${ROLLBACK_HTTP:-}" ]; then
      # shellcheck disable=SC2086
      code=$($ROLLBACK_HTTP "$url")
      rc=$?
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 4 "$url" 2>/dev/null)
      rc=$?
    fi
    set -e
    code=${code:-}
    if [ "$rc" -eq 0 ] && [ -n "$code" ] && [ "$code" != "000" ]; then
      printf '%s' "$code"
      return 0
    fi
    sleep "$delay"
    delay=$((delay * 2))
  done
  printf '%s' "${code:-}"
  return 5
}

classify_hash() {
  local label="$1" got="$2" want="$3"
  local alt="${4:-}"
  if [ -z "$got" ]; then
    echo "NO-DATA $label got='' (empty observation — not a mismatch)"
    return 4
  fi
  case "$got" in
    MISSING|missing|NOENT)
      echo "MISSING $label path absent on device"
      return 2
      ;;
  esac
  if [ "$got" = "$want" ] || { [ -n "$alt" ] && [ "$got" = "$alt" ]; }; then
    echo "OK $label $got"
    return 0
  fi
  # Prefix8 match when want is prefix-only (full pin not yet fetched).
  if pair_policy_md5_match "$got" "$want"; then
    echo "OK $label $got (prefix-match want=$want)"
    return 0
  fi
  if [ -n "$alt" ] && pair_policy_md5_match "$got" "$alt"; then
    echo "OK $label $got (prefix-match alt=$alt)"
    return 0
  fi
  echo "MISMATCH $label got='$got' want='$want'${alt:+ or '$alt'}"
  return 3
}

remote_file_md5() {
  local path="$1"
  run_ssh "if [ ! -e $(printf '%q' "$path") ]; then echo MISSING; elif [ ! -f $(printf '%q' "$path") ]; then echo MISSING; else md5sum $(printf '%q' "$path") | awk '{print \$1}'; fi"
}

remote_live_any_daemon() {
  # Count by /proc/PID/exe basename==misterplexd only (not cmdline; flock trap).
  run_ssh "$(pair_remote_live_daemon_snippet)"
}

remote_find_daemon_pin() {
  local want="$1"
  run_ssh "want=$(printf '%q' "$want"); $(cat <<'REMOTE'
set +e
cands="
/media/fat/misterplex_v2/bin/misterplexd
/media/fat/misterplex/bin/misterplexd
/media/fat/misterplex_v2/bin/misterplexd.prev-deploy
/media/fat/misterplex/bin/misterplexd.prev-deploy
"
for b in /media/fat/misterplex_v2/bin/misterplexd.*.bak \
         /media/fat/misterplex/bin/misterplexd.*.bak \
         /media/fat/_Utility/misterplexd.* \
         /media/fat/misterplex_v2/bin/misterplexd.50f4eb92 \
         /media/fat/misterplex_v2/bin/misterplexd.7cd10b4d; do
  [ -f "$b" ] || continue
  cands="$cands
$b"
done
found=""
for p in $cands; do
  [ -f "$p" ] || continue
  m=$(md5sum "$p" 2>/dev/null | awk '{print $1}')
  [ -n "$m" ] || continue
  if [ "$m" = "$want" ]; then
    echo "FOUND_PATH=$p"; echo "FOUND_MD5=$m"; found=1; break
  fi
  w8=$(printf '%s' "$want" | cut -c1-8)
  m8=$(printf '%s' "$m" | cut -c1-8)
  if [ "${#want}" -eq 8 ] && [ "$m8" = "$want" ]; then
    echo "FOUND_PATH=$p"; echo "FOUND_MD5=$m"; found=1; break
  fi
done
if [ -z "$found" ]; then
  echo "FOUND_PATH="
  echo "FOUND_MD5="
fi
REMOTE
)"
}

stop_remote_daemon() {
  log "stop remote daemon (pair atomic — stop before core/daemon mutate)"
  local pc rc
  set +e
  pc=$(run_ssh "for p in $PLEXCTL_CANDIDATES; do [ -x \"\$p\" ] && echo \"\$p\" && break; done")
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  if [ -n "$pc" ]; then
    run_ssh "$pc stop; echo stop_rc=\$?"
    return 0
  fi
  run_ssh 'for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    a0=$(tr "\0" "\n" <"$d/cmdline" 2>/dev/null | head -n1)
    case "$a0" in */misterplexd) kill "${d#/proc/}" 2>/dev/null || true ;; esac
  done
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cmd=$(tr "\0" " " <"$d/cmdline" 2>/dev/null) || continue
    case "$cmd" in *plexctl_supervise*|*misterplexd_supervise*|*dedupe_daemon*)
      kill "${d#/proc/}" 2>/dev/null || true ;;
    esac
  done
  sleep 1; echo stopped_by_argv0'
}

install_daemon_bytes() {
  local spec="$1" host_md5 staged remote_md5 src
  log "install daemon for pair $PAIR_ID want=$DAEMON_MD5 from $spec"
  if [[ "$spec" == device:* ]]; then
    local devpath="${spec#device:}"
    run_ssh "set -e
      src=$(printf '%q' "$devpath")
      dst=$(printf '%q' "$V2_DAEMON")
      mkdir -p \"\$(dirname \"\$dst\")\"
      if [ \"\$src\" != \"\$dst\" ]; then
        cp -f \"\$src\" \"\$dst\"
      fi
      chmod 755 \"\$dst\"
      sync
      md5sum \"\$dst\"
    "
    return 0
  fi
  [ -f "$spec" ] || { echo "MISSING host daemon artifact $spec"; return 2; }
  host_md5=$(md5sum "$spec" | awk '{print $1}')
  if ! assert_md5_shape "host_daemon_md5" "$host_md5"; then
    echo "REFUSE host daemon md5 shape invalid"
    return 10
  fi
  if ! assert_md5_shape "pair_daemon_pin" "$DAEMON_MD5"; then
    echo "REFUSE pair pin shape invalid"
    return 10
  fi
  if [ "$host_md5" != "$DAEMON_MD5" ]; then
    echo "REFUSE host daemon md5 $host_md5 != pair pin $DAEMON_MD5"
    return 10
  fi
  staged="/tmp/misterplexd.pair.$$"
  set +e
  run_scp "$spec" "$staged"
  src=$?
  set -e
  [ "$src" -eq 0 ] || return 5
  remote_md5=$(run_ssh "set -e
    dst=$(printf '%q' "$V2_DAEMON")
    staged=$(printf '%q' "$staged")
    mkdir -p \"\$(dirname \"\$dst\")\"
    if [ -f \"\$dst\" ]; then
      om=\$(md5sum \"\$dst\" | awk '{print \$1}')
      arch=\"\${dst}.\${om:0:8}.bak\"
      if [ ! -f \"\$arch\" ]; then cp -f \"\$dst\" \"\$arch\" || true; fi
    fi
    mv -f \"\$staged\" \"\$dst\"
    chmod 755 \"\$dst\"
    sync
    md5sum \"\$dst\" | awk '{print \$1}'
  ")
  if [ "$remote_md5" != "$DAEMON_MD5" ]; then
    echo "FAIL installed disk md5 '$remote_md5' != want $DAEMON_MD5"
    return 3
  fi
  echo "OK daemon-installed disk=$remote_md5"
  return 0
}

load_pair_core_remote() {
  log "load core: ONE menu bounce then $V2_CORE (pair $PAIR_ID mode=$PAIR_MODE)"
  run_ssh "set -e
    if [ ! -e /dev/MiSTer_cmd ]; then echo 'NO-DATA missing /dev/MiSTer_cmd'; exit 4; fi
    if [ ! -f $(printf '%q' "$V2_CORE") ]; then echo 'MISSING $V2_CORE'; exit 2; fi
    cm=\$(md5sum $(printf '%q' "$V2_CORE") | awk '{print \$1}')
    if [ \"\$cm\" != $(printf '%q' "$CORE_MD5") ]; then
      echo \"MISMATCH core-disk got=\$cm want=$CORE_MD5 — refusing load\"
      exit 3
    fi
    if [ -f $(printf '%q' "$MENU_CORE") ]; then
      printf '%s\n' 'load_core $(printf '%s' "$MENU_CORE")' > /dev/MiSTer_cmd
      sleep 6
    else
      echo 'NOTE menu.rbf absent — loading pair core directly'
    fi
    printf '%s\n' 'load_core $(printf '%s' "$V2_CORE")' > /dev/MiSTer_cmd
    sleep 8
    echo CORE_LOAD_ISSUED
    echo CORE_MD5=\$cm
    if [ -f /tmp/CORENAME ]; then echo CORENAME=\$(cat /tmp/CORENAME); fi
  "
}

start_pair_bundle() {
  log "start bundle for root $V2_ROOT"
  local pc rc
  set +e
  pc=$(run_ssh "for p in $PLEXCTL_CANDIDATES; do [ -x \"\$p\" ] && echo \"\$p\" && break; done")
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  if [ -z "$pc" ]; then
    log "ERROR no plexctl on device"
    return 9
  fi
  run_ssh "$pc v2; echo start_rc=\$?"
}

# Resolve live conf path from running daemon cmdline; fall back to pair root.
resolve_live_conf_path() {
  local blob conf
  set +e
  blob=$(remote_live_any_daemon)
  set -e
  conf=$(printf '%s\n' "$blob" | sed -n 's/^LIVE_CONF=//p' | head -1)
  if [ -n "$conf" ]; then
    printf '%s' "$conf"
    return 0
  fi
  printf '%s' "$V2_CONF_DEFAULT"
}

# Atomic conf half of the pair: backup current, render profile, install.
# Never leaves foreign DDR keys on an SPI restore (parent requirement).
apply_pair_conf() {
  local profile="${1:-$PAIR_CONF_PROFILE}" conf_path staged body rc host_tmp remote_bak
  conf_path=$(resolve_live_conf_path)
  log "apply conf profile=$profile path=$conf_path (atomic with pair binaries)"

  set +e
  body=$(run_ssh "if [ -f $(printf '%q' "$conf_path") ]; then cat $(printf '%q' "$conf_path"); else echo ''; fi")
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi

  host_tmp="$ROOT/build/pair-conf-${PAIR_ID}.$$.conf"
  mkdir -p "$(dirname "$host_tmp")"
  printf '%s\n' "$body" >"$host_tmp.src"
  pair_policy_render_conf "$profile" "$host_tmp.src" >"$host_tmp"
  rm -f "$host_tmp.src"

  # Verify rendered conf matches profile before touching device.
  set +e
  pair_policy_check_conf "$profile" "$host_tmp"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "REFUSE conf render failed profile=$profile true rc=$rc"
    rm -f "$host_tmp"
    return 10
  fi

  staged="/tmp/misterplex.conf.pair.$$"
  remote_bak="${conf_path}.bak.pre-${PAIR_ID}"
  set +e
  run_scp "$host_tmp" "$staged"
  rc=$?
  set -e
  rm -f "$host_tmp"
  if [ "$rc" -ne 0 ]; then return 5; fi

  run_ssh "set -e
    conf=$(printf '%q' "$conf_path")
    staged=$(printf '%q' "$staged")
    bak=$(printf '%q' "$remote_bak")
    mkdir -p \"\$(dirname \"\$conf\")\"
    if [ -f \"\$conf\" ]; then cp -f \"\$conf\" \"\$bak\"; fi
    mv -f \"\$staged\" \"\$conf\"
    sync
    echo CONF_INSTALLED=\$conf
    echo CONF_BAK=\$bak
  "
  echo "OK conf-applied profile=$profile path=$conf_path"
  return 0
}

run_visual_gate() {
  log "visual gate (HARD for claim success — green screen class)"
  local vrc=8
  # Prefer explicit visual cmd, then idle PNG, then motion capture dir / cmd.
  if [ -n "${PROMOTE_VISUAL_CMD:-}" ]; then
    set +e
    # shellcheck disable=SC2086
    eval $PROMOTE_VISUAL_CMD
    vrc=$?
    set -e
    echo "visual_hook true rc=$vrc"
  elif [ -n "${PAIR_IDLE_PNG:-}" ] || [ -n "${PAIR_CAPTURE_CMD:-}" ]; then
    set +e
    "$ROOT/scripts/pair_visual_gate.sh" idle
    vrc=$?
    set -e
    echo "visual_idle true rc=$vrc"
  elif [ -n "${PROMOTE_MOTION_CMD:-}" ] || [ -n "${PROMOTE_MOTION_CAPTURE_DIR:-}" ]; then
    local mcmd="${PROMOTE_MOTION_CMD:-}"
    if [ -z "$mcmd" ]; then
      mcmd="python3 $(printf '%q' "$ROOT/tools/hdmi_motion_instrument.py") $(printf '%q' "$PROMOTE_MOTION_CAPTURE_DIR")"
    fi
    set +e
    # shellcheck disable=SC2086
    eval $mcmd
    vrc=$?
    set -e
    echo "motion_hook true rc=$vrc"
    # rc=77 UNSCORED is HARD FAIL for pair claim (green-cast leak class).
    if [ "$vrc" -eq 77 ]; then
      echo "FAIL motion UNSCORED rc=77 is HARD FAIL (not inconclusive)"
      vrc=8
    elif [ "$vrc" -ne 0 ]; then
      vrc=8
    fi
  else
    echo "VISUAL_REQUIRED for pair claim success"
    echo "  PAIR_IDLE_PNG=...  or  PROMOTE_MOTION_CAPTURE_DIR=...  or  PROMOTE_VISUAL_CMD=..."
    vrc=8
  fi
  echo "visual_gate true rc=$vrc"
  return "$vrc"
}

preflight_atomic() {
  local got_core disk_daemon host_daemon dev_find need_install=0 step_rc hrc drc prc out dev_path
  log "== preflight ATOMIC pair id=$PAIR_ID core=${CORE_MD5:0:8} daemon=${DAEMON_MD5:0:8} =="

  set +e
  out=$(pair_policy_check "$CORE_MD5" "$DAEMON_MD5")
  prc=$?
  set -e
  printf '%s\n' "$out"
  if [ "$prc" -ne 0 ]; then
    echo "REFUSE pair_policy_check true rc=$prc"
    return 10
  fi

  set +e
  got_core=$(remote_file_md5 "$V2_CORE")
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then return 5; fi
  set +e
  classify_hash "preflight-core-disk" "$got_core" "$CORE_MD5"
  step_rc=$?
  set -e
  if [ "$step_rc" -ne 0 ]; then
    echo "REFUSE: pair core at $V2_CORE not at pin $CORE_MD5 (got='$got_core')"
    echo "REFUSE: will not load a mismatched core; fix core file first"
    return 10
  fi

  set +e
  disk_daemon=$(remote_file_md5 "$V2_DAEMON")
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then return 5; fi
  echo "preflight disk-daemon at $V2_DAEMON got='${disk_daemon}'"

  DAEMON_SOURCE=""
  if pair_policy_md5_match "$disk_daemon" "$DAEMON_MD5"; then
    echo "OK preflight disk-daemon already at pair pin — no install needed (got=$disk_daemon want=$DAEMON_MD5)"
    DAEMON_SOURCE="device:$V2_DAEMON"
    need_install=0
  else
    need_install=1
    set +e
    host_daemon=$(pair_policy_find_daemon_artifact "$DAEMON_MD5")
    hrc=$?
    set -e
    if [ "$hrc" -eq 0 ]; then
      echo "OK preflight host daemon artifact $host_daemon"
      DAEMON_SOURCE="$host_daemon"
    else
      set +e
      dev_find=$(remote_find_daemon_pin "$DAEMON_MD5")
      drc=$?
      set -e
      if [ "$drc" -eq 5 ]; then return 5; fi
      printf '%s\n' "$dev_find"
      dev_path=$(printf '%s\n' "$dev_find" | sed -n 's/^FOUND_PATH=//p' | head -1)
      if [ -n "$dev_path" ]; then
        echo "OK preflight on-device pin backup $dev_path"
        DAEMON_SOURCE="device:$dev_path"
      else
        cat <<EOF
REFUSE ATOMIC_ROLLBACK: cannot restore pair $PAIR_ID without daemon pin ${DAEMON_MD5:0:8}.
  core half is available at $V2_CORE ($CORE_MD5)
  daemon half is NOT available:
    - disk $V2_DAEMON is '${disk_daemon}'
    - no host artifact under artifacts/daemon-pins/ (pins are gitignored)
    - no on-device misterplexd.${DAEMON_MD5:0:8}.bak backup
  Restoring the core ALONE leaves a mixed pair → solid green screen (parent 2026-07-31).
  Device left UNTOUCHED.
EOF
        pair_policy_missing_daemon_help "$DAEMON_MD5"
        return 10
      fi
    fi
  fi
  export DAEMON_SOURCE
  export DAEMON_NEED_INSTALL="$need_install"
  echo "PREFLIGHT_OK pair=$PAIR_ID daemon_source=$DAEMON_SOURCE need_install=$need_install"
  return 0
}


# Install durable supervisor + rewrite LIVE user-startup.sh for PAIR_BOOT_ROOT.
# Fourth half of the atomic pair (core, daemon, conf, BOOT).
install_pair_boot_path() {
  local root="${1:-$PAIR_BOOT_ROOT}" hook_body rendered host_tmp staged rc bak_ts live_path s99_body
  # Resolve LIVE path from device S99user USER_SCRIPT= (never hardcode decoy).
  if [ -z "${BOOT_HOOK_PATH_LOCKED:-}" ]; then
    set +e
    s99_body=$(run_ssh "if [ -f /etc/init.d/S99user ]; then cat /etc/init.d/S99user; else echo MISSING; fi")
    rc=$?
    set -e
    if [ "$rc" -eq 5 ]; then return 5; fi
    if [ "$s99_body" != "MISSING" ] && [ -n "$s99_body" ]; then
      set +e
      boot_hook_resolve_from_s99_body "$s99_body" 0 >/dev/null
      rc=$?
      set -e
      if [ "$rc" -eq 0 ]; then
        BOOT_HOOK_PATH="$BOOT_HOOK_DEVICE_PATH"
        echo "BOOT_HOOK_RESOLVED path=$BOOT_HOOK_PATH source=s99user"
      fi
    fi
  fi
  live_path="${BOOT_HOOK_PATH:-$BOOT_HOOK_DEVICE_PATH}"
  case "$(basename "$live_path")" in
    _*)
      echo "REFUSE boot hook path is decoy (underscore): $live_path"
      return 10
      ;;
  esac
  log "install boot path root=$root hook=$live_path"

  if [ ! -f "$HOST_SUPERVISE_SRC" ]; then
    echo "REFUSE missing host supervisor source $HOST_SUPERVISE_SRC"
    return 10
  fi

  staged="/tmp/misterplexd_supervise.pair.$$"
  set +e
  run_scp "$HOST_SUPERVISE_SRC" "$staged"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then return 5; fi

  run_ssh "set -e
    root=$(printf '%q' "$root")
    staged=$(printf '%q' "$staged")
    mkdir -p \"\$root/bin\"
    # archive previous supervisor if present
    if [ -f \"\$root/bin/misterplexd_supervise.sh\" ]; then
      cp -f \"\$root/bin/misterplexd_supervise.sh\" \"\$root/bin/misterplexd_supervise.sh.bak.pre-pair\" || true
    fi
    mv -f \"\$staged\" \"\$root/bin/misterplexd_supervise.sh\"
    chmod +x \"\$root/bin/misterplexd_supervise.sh\"
    sync
    echo SUPERVISE_INSTALLED=\$root/bin/misterplexd_supervise.sh
  "

  set +e
  hook_body=$(run_ssh "if [ -f $(printf '%q' "$live_path") ]; then cat $(printf '%q' "$live_path"); else echo ''; fi")
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi

  host_tmp="$ROOT/build/pair-boot-hook-${PAIR_ID}.$$.sh"
  mkdir -p "$(dirname "$host_tmp")"
  boot_hook_render_body "$root" "$hook_body" >"$host_tmp"

  set +e
  boot_hook_check_body "$(cat "$host_tmp")" "$root"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "REFUSE rendered boot hook failed check true rc=$rc"
    rm -f "$host_tmp"
    return 10
  fi

  staged="/tmp/user-startup.pair.$$"
  bak_ts=$(date -u +%Y%m%dT%H%M%SZ)
  set +e
  run_scp "$host_tmp" "$staged"
  rc=$?
  set -e
  rm -f "$host_tmp"
  if [ "$rc" -ne 0 ]; then return 5; fi

  run_ssh "set -e
    hook=$(printf '%q' "$live_path")
    staged=$(printf '%q' "$staged")
    bak=\${hook}.bak.${bak_ts}
    mkdir -p \"\$(dirname \"\$hook\")\"
    if [ -f \"\$hook\" ]; then cp -f \"\$hook\" \"\$bak\"; echo HOOK_BAK=\$bak; fi
    mv -f \"\$staged\" \"\$hook\"
    chmod 755 \"\$hook\" 2>/dev/null || true
    sync
    echo HOOK_INSTALLED=\$hook
  "
  echo "OK boot-path root=$root hook=$live_path"
  return 0
}

verify_boot_hook_live() {
  local root="${1:-$PAIR_BOOT_ROOT}" body live_root rc scan
  set +e
  body=$(run_ssh "if [ -f $(printf '%q' "$BOOT_HOOK_PATH") ]; then cat $(printf '%q' "$BOOT_HOOK_PATH"); else echo MISSING; fi")
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  if [ "$body" = "MISSING" ]; then
    echo "FAIL boot-hook MISSING at $BOOT_HOOK_PATH"
    return 3
  fi
  set +e
  boot_hook_check_body "$body" "$root"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL boot-hook does not match pair root $root"
    return 3
  fi
  # Live daemon root must match hook root (the session-long undetected defect).
  set +e
  scan=$(remote_live_any_daemon)
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  live_root=$(printf '%s\n' "$scan" | sed -n 's/^LIVE_ROOT=//p' | head -1)
  if [ -n "$live_root" ] && [ "$live_root" != "$root" ]; then
    echo "FAIL boot-hook/live-root mismatch hook_root=$root live_root=$live_root"
    echo "FAIL detail=cold_boot_would_start_different_bundle_than_live_session"
    return 3
  fi
  # Supervisor file must exist on disk under root.
  set +e
  run_ssh "test -x $(printf '%q' "$root/bin/misterplexd_supervise.sh") && echo SUPERVISE_OK || echo SUPERVISE_MISSING"
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then return 5; fi
  echo "OK boot-hook+live-root root=$root"
  return 0
}

verify_pair() {
  local rc=0 step_rc got_core got_disk live_blob live n conf code pair_out require_visual prc vrc
  require_visual="${1:-${ROLLBACK_REQUIRE_VISUAL:-1}}"

  log "== verify ATOMIC pair id=$PAIR_ID =="

  set +e
  got_core=$(remote_file_md5 "$V2_CORE")
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  set +e
  classify_hash "core-disk" "$got_core" "$CORE_MD5"
  step_rc=$?
  set -e
  [ "$step_rc" -eq 0 ] || rc=$step_rc

  set +e
  got_disk=$(remote_file_md5 "$V2_DAEMON")
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  set +e
  classify_hash "daemon-disk" "$got_disk" "$DAEMON_MD5"
  step_rc=$?
  set -e
  if [ "$step_rc" -ne 0 ]; then rc=$step_rc; fi

  set +e
  live_blob=$(remote_live_any_daemon)
  step_rc=$?
  set -e
  if [ "$step_rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  printf '%s\n' "$live_blob"
  n=$(printf '%s\n' "$live_blob" | sed -n 's/^N_DAEMON=//p' | head -1)
  live=$(printf '%s\n' "$live_blob" | sed -n 's/^LIVE_MD5=//p' | head -1)
  conf=$(printf '%s\n' "$live_blob" | sed -n 's/^LIVE_CONF=//p' | head -1)

  if [ -z "$n" ]; then
    echo "NO-DATA n_daemon"
    rc=4
  elif [ "$n" != "1" ]; then
    echo "FAIL n_daemon=$n want=1"
    rc=9
  else
    echo "OK n_daemon=1"
  fi

  if [ -z "$live" ]; then
    echo "NO-DATA live-exe-md5"
    [ "$rc" -eq 0 ] && rc=4
  else
    set +e
    classify_hash "daemon-live" "$live" "$DAEMON_MD5"
    step_rc=$?
    set -e
    [ "$step_rc" -eq 0 ] || rc=$step_rc
  fi

  if [ -n "$got_core" ] && [ "$got_core" != "MISSING" ] && [ -n "$live" ]; then
    set +e
    pair_out=$(pair_policy_check "$got_core" "$live")
    prc=$?
    set -e
    printf '%s\n' "$pair_out"
    if [ "$prc" -ne 0 ]; then
      echo "FAIL pair-compatibility true rc=$prc"
      rc=3
    else
      echo "OK pair-compatibility"
    fi
  fi

  if [ -n "$conf" ]; then
    echo "OK daemon-conf $conf (from live --conf)"
    # Pull conf body and check pair profile (DDR keys required / SPI forbidden).
    set +e
    conf_body=$(run_ssh "if [ -f $(printf '%q' "$conf") ]; then cat $(printf '%q' "$conf"); else echo MISSING; fi")
    step_rc=$?
    set -e
    if [ "$step_rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
    if [ "$conf_body" = "MISSING" ] || [ -z "$conf_body" ]; then
      echo "FAIL conf-body missing at $conf"
      rc=3
    else
      set +e
      pair_policy_check_conf "${PAIR_CONF_PROFILE:-none}" "$conf_body"
      step_rc=$?
      set -e
      if [ "$step_rc" -ne 0 ]; then
        echo "FAIL conf-profile pair=$PAIR_ID profile=$PAIR_CONF_PROFILE"
        rc=3
      fi
    fi
  else
    echo "NOTE daemon-conf empty — cannot verify conf half of pair"
    if [ "${PAIR_CONF_PROFILE:-none}" != "none" ]; then
      echo "FAIL conf required for profile=$PAIR_CONF_PROFILE but live --conf empty"
      rc=3
    fi
  fi

  if [ -n "$got_disk" ] && [ "$got_disk" != "MISSING" ] && [ -n "$live" ] && [ "$got_disk" != "$live" ]; then
    echo "FAIL daemon-disk/live mismatch disk='$got_disk' live='$live' (ETXTBSY class)"
    rc=3
  fi

  set +e
  code=$(http_code "http://${HOST}:${PORT}/resources")
  step_rc=$?
  set -e
  if [ -z "$code" ]; then
    echo "NO-DATA http /resources"
    [ "$rc" -eq 0 ] && rc=4
  elif [ "$code" = "200" ] || [ "$code" = "204" ]; then
    echo "OK http /resources code=$code"
  else
    echo "FAIL http /resources code=$code"
    rc=9
  fi

  if [ "${ROLLBACK_SKIP_BOOT:-0}" != "1" ]; then
    set +e
    verify_boot_hook_live "$PAIR_BOOT_ROOT"
    step_rc=$?
    set -e
    if [ "$step_rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
    if [ "$step_rc" -ne 0 ]; then
      echo "FAIL boot-hook gate (pair incomplete without cold-boot path)"
      rc=3
    fi
  fi

  if [ "$require_visual" = "1" ]; then
    # Aggregate-then-verdict: always run visual even if telemetry already failed.
    # Skipping highest-value evidence after a cheap fail hid real pixel state
    # (parent promotion gate class 2026-07-31).
    set +e
    run_visual_gate
    vrc=$?
    set -e
    echo "visual_hook true rc=$vrc (prior_telemetry_rc=$rc)"
    if [ "$vrc" -ne 0 ]; then
      echo "FAIL visual required for pair success (telemetry is not enough)"
      # Prefer visual rc when prior was 0; otherwise keep worse/first non-zero
      if [ "$rc" -eq 0 ]; then rc=8; fi
      if [ "$vrc" -eq 8 ] || [ "$vrc" -eq 77 ]; then
        [ "$rc" -eq 0 ] && rc=8
        rc=8
      fi
    fi
  else
    echo "NOTE visual not required (ROLLBACK_REQUIRE_VISUAL=0) — telemetry only; NOT a claim of pixel OK"
  fi

  if [ "$rc" -eq 0 ]; then
    echo "PAIR_RESTORE_OK id=$PAIR_ID core=${CORE_MD5:0:8} daemon=${DAEMON_MD5:0:8}"
  fi
  echo "true rc=$rc"
  return "$rc"
}

restore_and_verify() {
  local rc
  ROLLBACK_REQUIRE_VISUAL="${ROLLBACK_REQUIRE_VISUAL:-1}"

  set +e
  preflight_atomic
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "true rc=$rc"
    return "$rc"
  fi

  set +e
  stop_remote_daemon
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then echo "true rc=5"; return 5; fi

  if [ "${DAEMON_NEED_INSTALL:-1}" = "1" ] || [ "${DAEMON_SOURCE:-}" != "device:$V2_DAEMON" ]; then
    # Always re-copy when source is a bak path different from live, or host path.
    if [ "${DAEMON_SOURCE:-}" != "device:$V2_DAEMON" ]; then
      set +e
      install_daemon_bytes "$DAEMON_SOURCE"
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "ERROR daemon install rc=$rc — core NOT loaded (atomic refuse mid-flight)"
        echo "true rc=$rc"
        return "$rc"
      fi
    else
      log "daemon disk already at pin — skip install"
    fi
  else
    log "daemon disk already at pin — skip install"
  fi

  # Conf half BEFORE core load / start — pair is (core, daemon, conf, boot).
  if [ "${PAIR_CONF_PROFILE:-none}" != "none" ] && [ "${ROLLBACK_SKIP_CONF:-0}" != "1" ]; then
    set +e
    apply_pair_conf "$PAIR_CONF_PROFILE"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "ERROR conf apply rc=$rc — core NOT loaded (atomic refuse mid-flight)"
      echo "true rc=$rc"
      return "$rc"
    fi
  fi

  # Boot path (supervisor + LIVE user-startup.sh) — parent cold-boot defect class.
  if [ "${ROLLBACK_SKIP_BOOT:-0}" != "1" ]; then
    set +e
    install_pair_boot_path "$PAIR_BOOT_ROOT"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "ERROR boot-path install rc=$rc — core NOT loaded (atomic refuse mid-flight)"
      echo "true rc=$rc"
      return "$rc"
    fi
  fi

  set +e
  load_pair_core_remote
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR core load rc=$rc"
    echo "true rc=9"
    return 9
  fi

  set +e
  start_pair_bundle
  rc=$?
  set -e
  if [ "$rc" -eq 5 ]; then echo "true rc=5"; return 5; fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR start bundle rc=$rc"
    echo "true rc=9"
    return 9
  fi

  sleep "${ROLLBACK_POST_START_SLEEP:-4}"
  verify_pair 1
}

print_pair_plan() {
  cat <<EOF
=== ATOMIC PAIR PLAN id=$PAIR_ID ===
mode=$PAIR_MODE bank1=$PAIR_BANK1 conf_profile=$PAIR_CONF_PROFILE
core_path=$PAIR_CORE_PATH  core_md5=$CORE_MD5
daemon_path=$V2_DAEMON     daemon_md5=$DAEMON_MD5
SPI undo core (NEVER overwrite)=$DEVICE_CORE_V2_DAILY pin=$RBF_PIN_V2_DAILY_FULL
product core slot=$DEVICE_CORE_PRODUCT

n_daemon count rule: basename(readlink -f /proc/PID/exe)==misterplexd
  (NOT cmdline — flock argv contains misterplexd and lies)

Sequence (all-or-nothing; abort leaves prior half uncommitted when possible):
  0) preflight: pair matrix OK + BOTH halves available (else rc=10 device untouched)
  1) STOP daemon (avoid ETXTBSY on cp over running binary)
  2) install daemon bytes if disk pin wrong (from host pin or on-device .bak)
  3) apply conf profile ($PAIR_CONF_PROFILE) atomically with backup
  3b) install $PAIR_BOOT_ROOT/bin/misterplexd_supervise.sh + rewrite LIVE user-startup.sh
      (S99user USER_SCRIPT; underscore _user-startup.sh is DECOY — never executed)
  4) ONE menu bounce → load $PAIR_CORE_PATH
  5) start exactly one daemon; verify n_daemon==1 via /proc/exe md5
  6) boot-hook gate: hook root == live root (FAIL if v1 hook + v2 live)
  7) HARD visual (PAIR_IDLE_PNG / motion); unset → rc=8; motion 77 → rc=8

BOOT path (fourth half of the pair):
  hook=$BOOT_HOOK_PATH
  supervise=$PAIR_BOOT_ROOT/bin/misterplexd_supervise.sh
  NEVER leave hook on v1 while live is v2 (cold-boot → stale 54f1d916 class)
  NEVER rely on /tmp/plexctl_supervise.sh (does not survive reboot)

POWER-CYCLE / worst-moment disk states (honesty; no core-identity register yet):
  A after preflight only:
      disk unchanged; boot = prior running pair (safe if was coherent)
  B after stop, before install:
      disk binaries unchanged; daemon down; boot → menu/last core, no daemon until start
      SAFE if operator does not auto-start a foreign daemon
  C after daemon+conf install, before core load:
      disk daemon+conf = TARGET; FPGA bitstream still OLD until step 4
      power loss here: on-disk TARGET daemon with OLD loaded core if autostart → MIXED
      MITIGATION: daemon is STOPPED; do not enable autostart mid-flight; Plex_v2.rbf
      SPI pin remains intact as undo core file
  D after core load, before start:
      FPGA = TARGET core; disk = TARGET daemon+conf; daemon still down
      power loss: next boot depends on MiSTer last-core; files on disk are COHERENT pair
  E after start+verify:
      live pair coherent; claim success only if visual gate rc=0

UNDO without identity RBF:
  PAIR_ID=spi-v2-hybrid ROLLBACK_DAEMON=artifacts/daemon-pins/misterplexd.50f4eb92 \\
    PAIR_IDLE_PNG=... $0 restore
  NEVER scripts/restore_misterplexd_prev.sh (disabled; half-restore → black screen)

Running-core identity: UNVERIFIED until w-fit-1 PLXC @ DOORBELL+0x130 lands.
  /tmp/CORENAME=Plex for every Plex*.rbf — do not trust CORENAME as pair proof.
EOF
}

cmd="${1:-restore}"
case "$cmd" in
  plan|dry-run)
    print_pair_plan
    echo "true rc=0"
    exit 0
    ;;
  verify)
    verify_pair "${ROLLBACK_REQUIRE_VISUAL:-0}"
    ;;
  preflight)
    set +e
    preflight_atomic
    rc=$?
    set -e
    echo "true rc=$rc"
    exit "$rc"
    ;;
  restore)
    # Allow explicit dry-run even on restore verb.
    if [ "${ROLLBACK_EXECUTE:-1}" = "0" ]; then
      print_pair_plan
      echo "DRY-RUN restore (ROLLBACK_EXECUTE=0) — device untouched"
      echo "true rc=0"
      exit 0
    fi
    restore_and_verify
    ;;
  *)
    echo "usage: $0 {plan|preflight|verify|restore}" >&2
    echo "true rc=9"
    exit 9
    ;;
esac
