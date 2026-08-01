#!/usr/bin/env bash
# Deploy a NAMED ARM misterplexd artifact to the LIVE MiSTer install root.
#
# Usage:
#   ./scripts/deploy_misterplexd.sh /path/to/misterplexd
#   DEPLOY_EXPECT_MD5=<md5> ./scripts/deploy_misterplexd.sh /path/to/misterplexd
#
# Contract (parent-measured defects 2026-07-30/31):
#   1) Ships the EXACT file named on the CLI (byte-for-byte). Never rebuilds
#      unless DEPLOY_REBUILD=1 (opt-in only).
#   2) Install root = live process root from readlink -f /proc/<pid>/exe
#      (not a hardcoded /media/fat/misterplex guess).
#   3) Stop → install → start ONE daemon → verify:
#        disk md5 == host md5 AND live /proc/PID/exe md5 == host md5
#        AND n_daemon == 1. Disk-only match is NOT success (ETXTBSY / no restart).
#   4) Every gate prints "true rc=N" captured directly (never through a pipe).
#
# Host unit tests inject DEPLOY_SSHM / DEPLOY_SCPM — never touches the real box.
set -euo pipefail
# Observation rules (parent ERROR 11 / 14):
#   got='' from probe → NO-DATA (rc path must not call it mismatch)
#   never pgrep (busybox missing → silent fail)
#   never cmdline substring "misterplexd" (flock)
#   PID capture + stop BEFORE any rename; verify live exe md5 AFTER

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=daemon_backup_policy.sh
source "$ROOT/scripts/daemon_backup_policy.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/deploy_misterplexd_lib.sh"

HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PMS_URL="${PLEX_BASE:-${PMS_URL:-}}"
PORT="${MISTERPLEX_PORT:-3005}"
DEPLOY_REBUILD="${DEPLOY_REBUILD:-0}"
EXPECT_MD5="${DEPLOY_EXPECT_MD5:-${EXPECT_MD5:-}}"
DEPLOY_SKIP_GEOMETRY_GATE="${DEPLOY_SKIP_GEOMETRY_GATE:-0}"
FORCE_ROOT="${MISTERPLEX_ROOT:-}"

# Explicit binary path: CLI arg > DEPLOY_BIN > default build path
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit 0
fi
if [[ $# -ge 1 && -n "${1:-}" ]]; then
  BIN="$1"
elif [[ -n "${DEPLOY_BIN:-}" ]]; then
  BIN="$DEPLOY_BIN"
else
  BIN="$ROOT/build/arm/misterplexd"
fi

ssh_m() {
  if [[ -n "${DEPLOY_SSHM:-}" ]]; then
    # shellcheck disable=SC2086
    $DEPLOY_SSHM "$@"
    return
  fi
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$USER@$HOST" "$@"
}

scp_to() {
  local src="$1" dst="$2"
  if [[ -n "${DEPLOY_SCPM:-}" ]]; then
    # shellcheck disable=SC2086
    $DEPLOY_SCPM "$src" "$dst"
    return
  fi
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$src" "$USER@$HOST:$dst"
}

die() { echo "FAIL deploy_misterplexd: $*" >&2; exit 1; }

report_rc() {
  # Usage: report_rc LABEL RC — prints true rc= without piping the command.
  local label="$1" rc="$2"
  echo "deploy: ${label}: true rc=${rc}"
  return "$rc"
}

# --- host artifact ------------------------------------------------------------
if [[ "$DEPLOY_REBUILD" == "1" ]]; then
  export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
  make -C "$ROOT" arm-plexd
  make_rc=$?
  report_rc "rebuild_arm-plexd" "$make_rc" || die "arm-plexd failed"
fi

[[ -f "$BIN" ]] || die "missing artifact $BIN (pass an explicit path: $0 /path/to/misterplexd)"
[[ -r "$BIN" ]] || die "unreadable artifact $BIN"
[[ -x "$BIN" ]] || chmod +x "$BIN" || true

HOST_MD5="$(md5sum "$BIN" | awk '{print $1}')"
HOST_SIZE="$(wc -c <"$BIN" | tr -d ' ')"
echo "deploy: host_artifact=$BIN"
echo "deploy: host_md5=$HOST_MD5"
echo "deploy: host_bytes=$HOST_SIZE"
if [[ -n "$EXPECT_MD5" && "$HOST_MD5" != "$EXPECT_MD5" ]]; then
  die "host md5 $HOST_MD5 != DEPLOY_EXPECT_MD5/EXPECT_MD5 $EXPECT_MD5 (refusing to ship unvalidated binary)"
fi

# --- resolve LIVE install root via readlink -f /proc/PID/exe ------------------
resolve_live_root() {
  ssh_m 'bash -s' <<'EOS'
echo DEPLOY_LIVE_PROBE
set +e
found=""
n=0
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
  case "$cmd" in
    *plexctl.sh*|*plexctl_supervise*|*misterplexd_supervise*|*dedupe_daemon*) continue ;;
  esac
  case "$cmd" in
    */misterplexd\ *|*/misterplexd) ;;
    *) continue ;;
  esac
  p=${d#/proc/}
  n=$((n + 1))
  # Prefer the kernel's view of the running image (parent-measured truth).
  exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
  if [ -n "$exe" ]; then
    root=$(dirname "$(dirname "$exe")")
  else
    conf=""
    set -- $cmd
    while [ $# -gt 0 ]; do
      if [ "$1" = "--conf" ]; then conf="${2:-}"; break; fi
      shift
    done
    if [ -n "$conf" ]; then
      root=$(dirname "$conf")
    else
      binpath=$(tr "\0" "\n" < "$d/cmdline" 2>/dev/null | head -n1)
      root=$(dirname "$(dirname "$binpath")")
      exe=$binpath
    fi
  fi
  conf=""
  set -- $cmd
  while [ $# -gt 0 ]; do
    if [ "$1" = "--conf" ]; then conf="${2:-}"; break; fi
    shift
  done
  live_md5=$(md5sum "/proc/$p/exe" 2>/dev/null | awk '{print $1}')
  echo "LIVE_PID=$p EXE=$exe ROOT=$root CONF=${conf:-} LIVE_MD5=${live_md5:-} CMD=$cmd"
  if [ -z "$found" ]; then
    found=$root
  elif [ "$found" != "$root" ]; then
    echo "MULTI_ROOT found=$found also=$root"
  fi
done
echo "N_DAEMON=$n"
if [ -n "$found" ]; then
  echo "ROOT=$found"
else
  echo "ROOT="
fi
EOS
}

LIVE_BLOB="$(resolve_live_root)" || { probe_rc=$?; report_rc "live_probe" "$probe_rc"; die "live probe ssh failed"; }
echo "$LIVE_BLOB" | sed 's/^/deploy: probe: /'
report_rc "live_probe" 0

if echo "$LIVE_BLOB" | grep -q '^MULTI_ROOT'; then
  die "multiple live daemon roots — stop extras before deploy (see probe lines)"
fi

LIVE_ROOT="$(echo "$LIVE_BLOB" | awk -F= '/^ROOT=/{print $2; exit}')"
LIVE_N="$(echo "$LIVE_BLOB" | awk -F= '/^N_DAEMON=/{print $2; exit}')"
LIVE_N="${LIVE_N:-0}"
echo "deploy: live_n_daemon=$LIVE_N live_root=${LIVE_ROOT:-"(none)"}"

rr=0
TARGET_ROOT="$(deploy_resolve_target_root "$LIVE_ROOT" "$FORCE_ROOT")" || rr=$?
if [[ "$rr" -eq 2 ]]; then
  die "live root is $LIVE_ROOT but MISTERPLEX_ROOT=$FORCE_ROOT — refusing cross-root deploy"
elif [[ "$rr" -eq 0 && -n "${TARGET_ROOT:-}" ]]; then
  if [[ -n "$FORCE_ROOT" ]]; then
    echo "deploy: target_root=$TARGET_ROOT (MISTERPLEX_ROOT override)"
  else
    echo "deploy: target_root=$TARGET_ROOT (from readlink -f /proc/PID/exe)"
  fi
else
  DETECT="$(ssh_m 'if [ -x /media/fat/misterplex_v2/bin/misterplexd ] || [ -f /media/fat/misterplex_v2/misterplex.conf ]; then echo /media/fat/misterplex_v2; elif [ -d /media/fat/misterplex ]; then echo /media/fat/misterplex; else echo /media/fat/misterplex_v2; fi')"
  TARGET_ROOT="$(echo "$DETECT" | tail -n1 | tr -d '\r')"
  echo "deploy: target_root=$TARGET_ROOT (no live daemon; defaulted to v2-first)"
fi

[[ -n "$TARGET_ROOT" ]] || die "empty target root"
[[ "$TARGET_ROOT" == /* ]] || die "target root must be absolute: $TARGET_ROOT"

REMOTE_BIN="$TARGET_ROOT/bin/misterplexd"
REMOTE_CONF="$TARGET_ROOT/misterplex.conf"
REMOTE_LOG="$TARGET_ROOT/misterplexd.log"

# DEPLOY ORDER (parent 2026-08-01 hand sequence — supervisor-safe):
#   1) CAPTURE daemon PIDs by /proc/comm+argv0 (NOT cmdline; NOT pgrep — busybox)
#      pidof misterplexd is OK as supplement; never match flock via cmdline substring
#   2) scp -> $BIN/misterplexd.stage.<host_prefix8>; md5 STAGED first
#   3) cp -p live -> misterplexd.bak.<measured_outgoing_prefix8> (+ canonical .PREFIX.bak)
#   4) mv stage onto live path  (rename OK while old inode still executing)
#   5) kill ONLY captured daemon PIDs  (leave supervisor alive)
#   6) supervisor restarts child; do NOT kill-then-manual-start when supervise present
#   7) verify md5sum "$(readlink -f /proc/NEWPID/exe)" == host  (never disk alone)
# Rename-before-kill trap: if you mv misterplexd -> misterplexd.bak.* first, then
# kill by *misterplexd exe glob, matches NOTHING and old keeps running.
# ETXTBSY sibling: never cp/write over running binary path; use stage+mv.
# got='' from probe = NO-DATA, never mismatch.

# --- 1) capture live daemon PIDs (before any file mutate) ---------------------
echo "deploy: capture daemon PIDs before stage/mv (supervisor stays up)"
set +e
CAP_OUT=$(ssh_m 'bash -s' <<'EOS'
set +e
pids=""
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  p=${d#/proc/}
  c=""; a0=""
  [ -r "$d/comm" ] && c=$(cat "$d/comm" 2>/dev/null || true)
  if [ "$c" = "misterplexd" ]; then
    pids="${pids}${pids:+ }$p"
    continue
  fi
  [ -r "$d/cmdline" ] || continue
  a0=$(tr "\0" "\n" < "$d/cmdline" 2>/dev/null | head -n1)
  case "$a0" in
    */misterplexd|misterplexd) pids="${pids}${pids:+ }$p" ;;
  esac
done
# supervisors present? (do not kill them in swap path)
nsup=0
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
  case "$cmd" in *plexctl.sh*) continue ;; esac
  case "$cmd" in
    *misterplexd_supervise.sh*|*plexctl_supervise.sh*|*dedupe_daemon.sh*) nsup=$((nsup+1)) ;;
  esac
done
echo "CAPTURED_PIDS=$pids"
echo "N_SUP_LIVE=$nsup"
EOS
)
cap_rc=$?
set -e
report_rc "capture_pids" "$cap_rc" || die "PID capture failed"
printf '%s\n' "$CAP_OUT" | sed 's/^/  [cap] /'
CAPTURED_PIDS=$(printf '%s\n' "$CAP_OUT" | sed -n 's/^CAPTURED_PIDS=//p' | head -1 | tr -d '\r')
N_SUP_LIVE=$(printf '%s\n' "$CAP_OUT" | sed -n 's/^N_SUP_LIVE=//p' | head -1 | tr -d '\r')
echo "deploy: captured_pids='${CAPTURED_PIDS:-}' n_sup_live=${N_SUP_LIVE:-0}"

# --- 2-4) stage → cp -p bak(measured md5) → mv (parent hand sequence) --------
echo "deploy: install host_md5=$HOST_MD5 -> $REMOTE_BIN (stage+cp -p bak+mv)"
HOST_P8="${HOST_MD5:0:8}"
# Stage beside live bin with measured prefix (parent: misterplexd.stage.3883f5ab)
STAGED_REMOTE="${REMOTE_BIN}.stage.${HOST_P8}"
set +e
ssh_m "set -e
  root='$TARGET_ROOT'
  mkdir -p \"\$root/bin\" \"\$root/scripts\"
  echo PREP_OK
"
prep_rc=$?
set -e
report_rc "install_prep" "$prep_rc" || die "install prep failed"

set +e
scp_to "$BIN" "$STAGED_REMOTE"
scp_rc=$?
set -e
report_rc "scp_stage" "$scp_rc" || die "scp to stage failed (stderr not suppressed)"

set +e
ssh_m "set -e
  staged='$STAGED_REMOTE'
  dst='$REMOTE_BIN'
  host_want='$HOST_MD5'
  host_p8='${HOST_P8}'
  # 1) md5 the STAGED file first (parent sequence)
  sm=\$(md5sum \"\$staged\" | awk '{print \$1}')
  echo STAGE_MD5=\$sm
  if [ \"\$sm\" != \"\$host_want\" ]; then
    echo \"FAIL stage md5 \$sm != host \$host_want\"
    rm -f \"\$staged\"
    exit 7
  fi
  if [ \"\${sm:0:8}\" != \"\$host_p8\" ]; then
    echo \"FAIL stage prefix \${sm:0:8} != \$host_p8\"
    exit 7
  fi
  # 2) backup LIVE bytes labeled with md5 they ACTUALLY are (cp -p; never mv live away)
  if [ -f \"\$dst\" ]; then
    om=\$(md5sum \"\$dst\" | awk '{print \$1}')
    op8=\${om:0:8}
    echo OUTGOING_MD5=\$om
    # canonical + parent alias; skip if already present with matching content
    canon=\"\${dst}.\${op8}.bak\"
    alias=\"\${dst}.bak.\${op8}\"
    if [ ! -f \"\$canon\" ]; then
      cp -p \"\$dst\" \"\$canon\"
      echo \"ARCHIVED_DAEMON \$canon md5=\$om\"
    else
      cm=\$(md5sum \"\$canon\" | awk '{print \$1}')
      if [ \"\$cm\" = \"\$om\" ]; then
        echo \"ARCHIVE_DAEMON_SKIP \$canon\"
      else
        echo \"FAIL archive path \$canon content \$cm != outgoing \$om (MISLABEL risk)\"
        exit 7
      fi
    fi
    if [ ! -f \"\$alias\" ]; then
      cp -p \"\$dst\" \"\$alias\" || true
      echo \"ARCHIVED_ALIAS \$alias\"
    fi
  else
    echo OUTGOING_MD5=MISSING
  fi
  # 3) mv stage onto live (rename survives execution; cp would ETXTBSY)
  mv -f \"\$staged\" \"\$dst\"
  chmod 755 \"\$dst\"
  sync
  dm=\$(md5sum \"\$dst\" | awk '{print \$1}')
  echo DISK_MD5=\$dm
  if [ \"\$dm\" != \"\$host_want\" ]; then
    echo \"FAIL disk md5 \$dm != host \$host_want after mv\"
    exit 7
  fi
  echo INSTALL_OK bak_prefix=\${op8:-none} new_prefix=\$host_p8
"
inst_rc=$?
set -e
report_rc "install_mv" "$inst_rc" || die "stage+cp_bak+mv failed (rc=$inst_rc)"

set +e
DISK_MD5="$(ssh_m "md5sum '$REMOTE_BIN'" | awk '{print $1}')"
disk_rc=$?
set -e
report_rc "disk_md5_probe" "$disk_rc" || die "disk md5 probe failed"
echo "deploy: disk_md5=$DISK_MD5"
if [[ -z "$DISK_MD5" ]]; then
  die "NO-DATA disk md5 empty (not a mismatch)"
fi
if [[ "$DISK_MD5" != "$HOST_MD5" ]]; then
  die "disk md5 $DISK_MD5 != host md5 $HOST_MD5 (install corrupted; not killing)"
fi
report_rc "disk_md5_match" 0

# --- 5) kill captured daemon PIDs only; leave supervisor to restart -----------
echo "deploy: kill captured daemon PIDs only (leave supervisor); pids='${CAPTURED_PIDS:-none}'"
set +e
ssh_m "set +e
  for p in $CAPTURED_PIDS; do
    [ -n \"\$p\" ] || continue
    if [ -d \"/proc/\$p\" ]; then
      c=\$(cat /proc/\$p/comm 2>/dev/null || echo '?')
      echo \"KILL_CAPTURED pid=\$p comm=\$c\"
      kill \"\$p\" 2>/dev/null || true
    else
      echo \"GONE_BEFORE_KILL pid=\$p\"
    fi
  done
  # brief wait for exit
  i=0
  while [ \$i -lt 40 ]; do
    left=0
    for p in $CAPTURED_PIDS; do
      [ -d \"/proc/\$p\" ] && left=\$((left+1))
    done
    [ \$left -eq 0 ] && break
    i=\$((i+1))
    sleep 0.25
  done
  echo KILL_WAIT_DONE
"
kill_rc=$?
set -e
report_rc "kill_captured" "$kill_rc" || die "kill captured failed"

# --- 6-7) supervisor restart (or fallback start); verify LIVE exe md5 ---------
echo "deploy: await supervisor restart root=$TARGET_ROOT (disk match alone is NOT success)"
set +e
ssh_m env \
  "PLAYER_ID=$PLAYER_ID" \
  "PMS_URL=$PMS_URL" \
  "PORT=$PORT" \
  "TARGET_ROOT=$TARGET_ROOT" \
  "REMOTE_BIN=$REMOTE_BIN" \
  "REMOTE_CONF=$REMOTE_CONF" \
  "REMOTE_LOG=$REMOTE_LOG" \
  "HOST_MD5=$HOST_MD5" \
  bash -s <<'REMOTE'
echo DEPLOY_RESTART_VERIFY
set -euo pipefail
chmod +x "$REMOTE_BIN"
chmod +x "$TARGET_ROOT/scripts/plex_browse.sh" "$TARGET_ROOT/scripts/plex_menu.sh" 2>/dev/null || true

# Conf is USER-OWNED. Never invent a default conf to make deploy succeed.
if [[ ! -f "$REMOTE_CONF" ]]; then
  if [[ "${DEPLOY_ALLOW_CREATE_CONF:-0}" == "1" ]]; then
    mkdir -p "$TARGET_ROOT"
    printf '# empty bootstrap; operator must fill\n' >"$REMOTE_CONF"
    echo "WARN created empty conf DEPLOY_ALLOW_CREATE_CONF=1 path=$REMOTE_CONF"
  else
    echo "FAIL conf missing at $REMOTE_CONF (user-owned; will not invent a default)"
    echo "     set DEPLOY_ALLOW_CREATE_CONF=1 only when intentionally bootstrapping"
    exit 8
  fi
fi

# Disk check again on-device (belt and suspenders).
disk_md5=$(md5sum "$REMOTE_BIN" | awk '{print $1}')
echo "REMOTE_DISK_MD5=$disk_md5"
if [[ "$disk_md5" != "$HOST_MD5" ]]; then
  echo "FAIL disk md5 $disk_md5 != host $HOST_MD5 before start"
  exit 5
fi

# Prefer supervisor respawn: wait up to ~15s for n_daemon==1 with live md5=host.
# Do not kill supervisors. Manual start only if no supervise and no daemon appears.
wait_live_match() {
  local i=0 p c a0 m n
  while [ "$i" -lt 60 ]; do
    n=0
    m=""
    for d in /proc/[0-9]*; do
      [ -d "$d" ] || continue
      p=${d#/proc/}
      c=""; [ -r "$d/comm" ] && c=$(cat "$d/comm" 2>/dev/null || true)
      is=0
      [ "$c" = "misterplexd" ] && is=1
      if [ "$is" -eq 0 ] && [ -r "$d/cmdline" ]; then
        a0=$(tr "\0" "\n" < "$d/cmdline" 2>/dev/null | head -n1)
        case "$a0" in */misterplexd|misterplexd) is=1 ;; esac
      fi
      [ "$is" -eq 1 ] || continue
      n=$((n+1))
      ep=$(readlink -f "$d/exe" 2>/dev/null || true)
      [ -n "$ep" ] || continue
      m=$(md5sum "$ep" 2>/dev/null | awk '{print $1}')
    done
    if [ "$n" -eq 1 ] && [ "$m" = "$HOST_MD5" ]; then
      echo "SUPERVISE_RESTART_OK live_md5=$m"
      return 0
    fi
    i=$((i+1))
    sleep 0.25
  done
  return 1
}

started=0
if wait_live_match; then
  started=1
  echo "START_PATH=supervisor_restart"
fi
for ctl in \
    "$TARGET_ROOT/scripts/plexctl.sh" \
    /media/fat/misterplex/scripts/plexctl.sh \
    /media/fat/Scripts/plexctl.sh \
    /media/fat/misterplex_v2/scripts/plexctl.sh
do
  if [[ -f "$ctl" ]]; then
    case "$TARGET_ROOT" in
      */misterplex_v2)
        if sh "$ctl" v2; then started=1; break; fi
        ;;
      */misterplex)
        if sh "$ctl" dev; then started=1; break; fi
        ;;
    esac
  fi
done

if [[ "$started" -ne 1 ]]; then
  PMS_ARG=""
  if [[ -n "${PMS_URL:-}" ]]; then PMS_ARG="--pms ${PMS_URL}"; fi
  : >>"$REMOTE_LOG"
  # shellcheck disable=SC2086
  nohup "$REMOTE_BIN" --name MiSTerPlex --id "${PLAYER_ID:-misterplex-dev}" --port "${PORT:-3005}" \
    --conf "$REMOTE_CONF" $PMS_ARG >>"$REMOTE_LOG" 2>&1 &
  # Give the process time to exec so /proc/PID/exe is the new image.
  sleep 1.5
fi

n=0
pids=""
live_md5=""
live_conf=""
live_exe=""
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  p=${d#/proc/}
  # Identity by comm + argv0 basename — NOT cmdline substring (flock trap).
  is_d=0
  if [ -r "$d/comm" ]; then
    c=$(cat "$d/comm" 2>/dev/null || true)
    [ "$c" = "misterplexd" ] && is_d=1
  fi
  if [ "$is_d" -eq 0 ] && [ -r "$d/cmdline" ]; then
    a0=$(tr "\0" "\n" < "$d/cmdline" 2>/dev/null | head -n1)
    case "$a0" in */misterplexd|misterplexd) is_d=1 ;; esac
  fi
  [ "$is_d" -eq 1 ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null || true)
  n=$((n + 1))
  pids="$pids $p"
  live_exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
  live_md5=$(md5sum "/proc/$p/exe" 2>/dev/null | awk '{print $1}')
  # conf from argv tokens
  set -- $cmd
  while [ $# -gt 0 ]; do
    if [ "$1" = "--conf" ]; then live_conf="${2:-}"; break; fi
    shift
  done
done
pids=$(echo "$pids" | xargs)

echo "POST_N_DAEMON=$n"
echo "POST_PIDS=$pids"
echo "POST_LIVE_EXE=$live_exe"
echo "POST_LIVE_MD5=$live_md5"
echo "POST_LIVE_CONF=$live_conf"
echo "POST_DISK_MD5=$disk_md5"
echo "POST_HOST_MD5=$HOST_MD5"
echo "POST_TARGET_ROOT=$TARGET_ROOT"

if [[ "$n" -ne 1 ]]; then
  echo "FAIL n_daemon=$n want=1 pids='$pids'"
  exit 3
fi
if [[ -z "$live_md5" ]]; then
  echo "FAIL empty /proc/PID/exe md5 — process may not have started"
  exit 4
fi
# THE critical check: LIVE image, not disk. Disk can be new while process is old.
if [[ "$live_md5" != "$HOST_MD5" ]]; then
  echo "FAIL live exe md5 $live_md5 != host artifact $HOST_MD5"
  echo "     disk_md5=$disk_md5 (disk-only match is NOT success — restart did not take)"
  exit 5
fi
if [[ "$disk_md5" != "$HOST_MD5" ]]; then
  echo "FAIL disk md5 $disk_md5 != host $HOST_MD5 after start"
  exit 5
fi
case "$live_conf" in
  "$TARGET_ROOT"/*) ;;
  *)
    echo "FAIL live --conf '$live_conf' not under target root $TARGET_ROOT"
    exit 6
    ;;
esac
case "$live_exe" in
  "$REMOTE_BIN"|"$TARGET_ROOT"/bin/*) ;;
  *)
    echo "FAIL live exe '$live_exe' not under $TARGET_ROOT/bin"
    exit 6
    ;;
esac

code=000
if command -v wget >/dev/null 2>&1; then
  code=$(wget -q -O /dev/null -S "http://127.0.0.1:${PORT:-3005}/resources" 2>&1 | awk '/HTTP\//{print $2; exit}')
  code=${code:-000}
fi
if [[ "$code" != "200" ]] && command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://127.0.0.1:${PORT:-3005}/resources" || echo 000)
fi
echo "POST_HTTP=$code"
if [[ "$code" != "200" ]]; then
  echo "FAIL /resources HTTP $code (daemon up but not healthy)"
  exit 7
fi
echo "DEPLOY_OK root=$TARGET_ROOT disk_md5=$disk_md5 live_md5=$live_md5 n_daemon=1 http=$code"
REMOTE
start_rc=$?
set -e
report_rc "restart_and_live_verify" "$start_rc" || die "restart/live verify failed (rc=$start_rc) — disk-only success is rejected"

echo "Deployed misterplexd → $HOST"
echo "deploy: summary host_md5=$HOST_MD5 target_root=$TARGET_ROOT remote_bin=$REMOTE_BIN"
echo "deploy: summary LIVE process md5 verified equal to host (not disk alone)"
report_rc "deploy_overall" 0

# --- boot path: durable supervisor + user-startup from S99user (P0 decoy fix) ---
# Old deploy wrote v1 bare misterplexd and grepped only 'misterplex/bin/misterplexd',
# which cannot match misterplex_v2. Also wrote _user-startup.sh DECOY — MiSTer runs
# USER_SCRIPT from /etc/init.d/S99user (user-startup.sh, no underscore).
if [[ "${DEPLOY_SKIP_BOOT_HOOK:-0}" != "1" ]]; then
  # shellcheck source=boot_hook_policy.sh
  source "$ROOT/scripts/boot_hook_policy.sh"
  SUP_SRC="$ROOT/scripts/misterplexd_supervise.sh"
  [[ -f "$SUP_SRC" ]] || die "missing $SUP_SRC"
  echo "deploy: install supervisor + boot hook for root=$TARGET_ROOT (path from S99user)"
  set +e
  scp_to "$SUP_SRC" "/tmp/misterplexd_supervise.deploy.$$"
  scp_rc=$?
  set -e
  report_rc "scp_supervise" "$scp_rc" || die "scp supervisor failed"
  set +e
  ssh_m "set -e
    root='$TARGET_ROOT'
    mkdir -p \"\$root/bin\"
    mv -f /tmp/misterplexd_supervise.deploy.$$ \"\$root/bin/misterplexd_supervise.sh\"
    chmod +x \"\$root/bin/misterplexd_supervise.sh\"
    INIT=/etc/init.d/S99user
    DECOY=/media/fat/linux/_user-startup.sh
    if [ ! -f \"\$INIT\" ]; then echo FAIL_NO_S99user; exit 8; fi
    line=\$(grep -E '^[[:space:]]*USER_SCRIPT=' \"\$INIT\" | tail -1)
    val=\${line#USER_SCRIPT=}
    val=\$(printf '%s' \"\$val\" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
    val=\$(printf '%s' \"\$val\" | sed 's/^\"//;s/\"\$//')
    if [ -z \"\$val\" ] || [ \"\${val#/}\" = \"\$val\" ]; then echo FAIL_USER_SCRIPT_UNPARSEABLE; exit 8; fi
    hook=\$val
    echo HOOK_FROM_INIT=\$hook
    mkdir -p \"\$(dirname \"\$hook\")\"
    touch \"\$hook\"
    bak=\${hook}.bak.\$(date -u +%Y%m%dT%H%M%SZ)
    cp -f \"\$hook\" \"\$bak\"
    tmp=\$(mktemp)
    grep -vE 'misterplexd_supervise\\.sh|/misterplex/bin/misterplexd|/misterplex_v2/bin/misterplexd' \"\$hook\" >\"\$tmp\" || true
    grep -vE '^# MiSTerPlex (pair autostart|companion|DECOY)' \"\$tmp\" >\"\$tmp.2\" || true
    mv -f \"\$tmp.2\" \"\$tmp\"
    printf '\\n# MiSTerPlex pair autostart (atomic with core+daemon+conf; do not hand-edit)\\n' >>\"\$tmp\"
    printf 'nohup %s/bin/misterplexd_supervise.sh >>%s/misterplexd_supervise.log 2>&1 &\\n' \"\$root\" \"\$root\" >>\"\$tmp\"
    mv -f \"\$tmp\" \"\$hook\"
    if [ -f \"\$DECOY\" ]; then
      dtmp=\$(mktemp)
      grep -vE 'misterplexd_supervise\\.sh|/misterplex/bin/misterplexd|/misterplex_v2/bin/misterplexd' \"\$DECOY\" >\"\$dtmp\" || true
      grep -vE '^# MiSTerPlex (pair autostart|companion|DECOY)' \"\$dtmp\" >\"\$dtmp.2\" || true
      printf '\\n# MiSTerPlex DECOY: underscore file is NOT run by S99user.\\n' >>\"\$dtmp.2\"
      mv -f \"\$dtmp.2\" \"\$DECOY\"
      rm -f \"\$dtmp\"
      echo DECOY_INERT=\$DECOY
    fi
    sync
    echo HOOK_BAK=\$bak
    echo HOOK_LINE=\$(grep misterplexd_supervise.sh \"\$hook\" | head -1)
    n=\$(grep -c misterplexd_supervise.sh \"\$hook\" || true)
    if [ \"\$n\" -ne 1 ]; then echo FAIL_HOOK_N=\$n; exit 8; fi
    if [ \"\$root\" = /media/fat/misterplex_v2 ] && grep -q '/misterplex/bin/misterplexd' \"\$hook\"; then
      echo FAIL_HOOK_V1_STILL_PRESENT; exit 8
    fi
    if [ -f \"\$DECOY\" ] && grep -qE 'misterplexd_supervise|/misterplex.*/bin/misterplexd' \"\$DECOY\"; then
      echo FAIL_DECOY_STILL_ARMED; exit 8
    fi
    echo BOOT_HOOK_OK
  "
  hook_rc=$?
  set -e
  report_rc "boot_hook" "$hook_rc" || die "boot hook install failed (rc=$hook_rc)"
fi

if [[ "$DEPLOY_SKIP_GEOMETRY_GATE" != "1" && -z "${DEPLOY_SSHM:-}" ]]; then
  set +e
  "$ROOT/scripts/check_core_conf_geometry.sh"
  geo_rc=$?
  set -e
  case "$geo_rc" in
    0) echo "core_conf_geometry: PASS"; report_rc "core_conf_geometry" 0 ;;
    77) echo "core_conf_geometry: SKIP-NOT-PASS (rc=77)" >&2; report_rc "core_conf_geometry_skip" 77 || true ;;
    *)
      echo "core_conf_geometry: FAIL rc=$geo_rc" >&2
      report_rc "core_conf_geometry" "$geo_rc" || exit "$geo_rc"
      ;;
  esac
fi
