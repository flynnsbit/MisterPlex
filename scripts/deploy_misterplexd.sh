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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=md5_shape.inc.sh
source "$ROOT/scripts/md5_shape.inc.sh"
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
if ! assert_md5_shape "host_artifact_md5" "$HOST_MD5"; then
  die "host md5 shape invalid (capture contaminated?)"
fi
if [[ -n "$EXPECT_MD5" ]]; then
  if ! assert_md5_shape "DEPLOY_EXPECT_MD5" "$EXPECT_MD5"; then
    die "EXPECT_MD5 shape invalid"
  fi
  if [[ "$HOST_MD5" != "$EXPECT_MD5" ]]; then
    die "host md5 $HOST_MD5 != DEPLOY_EXPECT_MD5/EXPECT_MD5 $EXPECT_MD5 (refusing to ship unvalidated binary)"
  fi
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

# --- stop every daemon/supervisor (cmdline match; no kill -9 storms) ----------
echo "deploy: stopping all misterplexd + supervisors"
set +e
ssh_m 'bash -s' <<'EOS'
set +e
SUPERVISORS="plexctl_supervise.sh misterplexd_supervise.sh dedupe_daemon.sh"
match_pids() {
  pat="$1"
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
    case "$cmd" in *plexctl.sh*) continue ;; esac
    case "$cmd" in *"$pat"*) echo "${d#/proc/}" ;; esac
  done
}
for pat in $SUPERVISORS misterplexd; do
  for p in $(match_pids "$pat"); do
    kill "$p" 2>/dev/null || true
  done
done
i=0
while [ "$i" -lt 40 ]; do
  left=0
  for pat in $SUPERVISORS misterplexd; do
    for p in $(match_pids "$pat"); do left=$((left + 1)); done
  done
  [ "$left" -eq 0 ] && break
  i=$((i + 1))
  sleep 0.25
done
left=0
for pat in $SUPERVISORS misterplexd; do
  for p in $(match_pids "$pat"); do
    left=$((left + 1))
    echo "STILL_UP pid=$p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)"
  done
done
if [ "$left" -ne 0 ]; then
  echo "STOP_FAILED n=$left"
  exit 9
fi
echo "STOP_OK"
EOS
stop_rc=$?
set -e
report_rc "stop_all" "$stop_rc" || die "stop failed (rc=$stop_rc)"

# --- install exact bytes ------------------------------------------------------
echo "deploy: install host_md5=$HOST_MD5 -> $REMOTE_BIN"
# Content-addressed archive of outgoing daemon so atomic pair rollback can find
# the previous pin (parent 2026-07-31: SPI rollback needed 50f4eb92 after DDR
# overwrite; without bak, restore cannot be atomic and must refuse).
set +e
ssh_m "echo DEPLOY_INSTALL_PREP root='$TARGET_ROOT'
mkdir -p '$TARGET_ROOT/bin' '$TARGET_ROOT/scripts'
if [ -f '$REMOTE_BIN' ]; then
  om=\$(md5sum '$REMOTE_BIN' 2>/dev/null | awk '{print \$1}')
  cp -f '$REMOTE_BIN' '$REMOTE_BIN.prev-deploy' || true
  if [ -n \"\$om\" ]; then
    arch='$REMOTE_BIN.'.\${om:0:8}.bak
    if [ ! -f \"\$arch\" ]; then
      cp -f '$REMOTE_BIN' \"\$arch\" && echo \"ARCHIVED_DAEMON \$arch\" || echo ARCHIVE_DAEMON_WARN
    else
      echo \"ARCHIVE_DAEMON_SKIP \$arch\"
    fi
  fi
fi
rm -f '$REMOTE_BIN'"
prep_rc=$?
set -e
report_rc "install_prep" "$prep_rc" || die "install prep failed"

set +e
scp_to "$BIN" "$REMOTE_BIN"
scp_rc=$?
set -e
report_rc "scp" "$scp_rc" || die "scp failed"

# Disk md5 on device MUST match host before we restart (catches partial scp).
set +e
DISK_MD5_RAW="$(ssh_m "md5sum '$REMOTE_BIN'")"
disk_rc=$?
set -e
report_rc "disk_md5_probe" "$disk_rc" || die "disk md5 probe failed"
DISK_MD5="${DISK_MD5_RAW%% *}"
DISK_MD5="${DISK_MD5//$''/}"
echo "deploy: disk_md5=$DISK_MD5"
if [[ -z "$DISK_MD5" ]]; then
  die "NO-DATA disk md5 empty (SSH drop — not a mismatch)"
fi
if ! assert_md5_shape "disk_md5" "$DISK_MD5"; then
  die "disk md5 shape invalid (probe glue/contamination)"
fi
if [[ "$DISK_MD5" != "$HOST_MD5" ]]; then
  die "disk md5 $DISK_MD5 != host md5 $HOST_MD5 (install corrupted; not restarting)"
fi
report_rc "disk_md5_match" 0

if [[ -f "$ROOT/scripts/plex_browse.sh" ]]; then
  scp_to "$ROOT/scripts/plex_browse.sh" "$TARGET_ROOT/scripts/plex_browse.sh" || true
  [[ -f "$ROOT/scripts/plex_menu.sh" ]] && scp_to "$ROOT/scripts/plex_menu.sh" "$TARGET_ROOT/scripts/plex_menu.sh" || true
fi

# --- restart exactly one daemon; verify LIVE exe md5 (not disk alone) ---------
echo "deploy: restart single daemon root=$TARGET_ROOT (disk match alone is NOT success)"
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

if [[ ! -f "$REMOTE_CONF" ]]; then
  mkdir -p "$TARGET_ROOT"
  cat >"$REMOTE_CONF" <<'CONF'
# Set PLEX_BASE=http://YOUR-PLEX-SERVER:32400
# PLEX_TOKEN=
CONF
  if [[ -n "${PMS_URL:-}" ]]; then
    printf 'PLEX_BASE=%s\n' "$PMS_URL" >>"$REMOTE_CONF"
  fi
fi

# Disk check again on-device (belt and suspenders).
disk_md5=$(md5sum "$REMOTE_BIN" | awk '{print $1}')
echo "REMOTE_DISK_MD5=$disk_md5"
if [[ "$disk_md5" != "$HOST_MD5" ]]; then
  echo "FAIL disk md5 $disk_md5 != host $HOST_MD5 before start"
  exit 5
fi

started=0
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
  [ -r "$d/cmdline" ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
  case "$cmd" in *plexctl.sh*|*supervise*|*dedupe_daemon*) continue ;; esac
  case "$cmd" in */misterplexd\ *|*/misterplexd) ;; *) continue ;; esac
  p=${d#/proc/}
  n=$((n + 1))
  pids="$pids $p"
  live_exe=$(readlink -f "/proc/$p/exe" 2>/dev/null || true)
  live_md5=$(md5sum "/proc/$p/exe" 2>/dev/null | awk '{print $1}')
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

# --- boot path: durable supervisor + LIVE USER_SCRIPT (never decoy) -------------
# Parent BLOCKER 2026-07-31: main wrote HOOK=/media/fat/linux/_user-startup.sh
# (never executed by S99user) + v1 root. Resolve LIVE path from S99user
# USER_SCRIPT= — hardcoding either path is the defect class.
if [[ "${DEPLOY_SKIP_BOOT_HOOK:-0}" != "1" ]]; then
  # shellcheck source=boot_hook_policy.sh
  source "$ROOT/scripts/boot_hook_policy.sh"
  SUP_SRC="$ROOT/scripts/misterplexd_supervise.sh"
  [[ -f "$SUP_SRC" ]] || die "missing $SUP_SRC"
  echo "deploy: install supervisor + boot hook for root=$TARGET_ROOT (path from S99user USER_SCRIPT)"
  set +e
  scp_to "$SUP_SRC" "/tmp/misterplexd_supervise.deploy.$$"
  scp_rc=$?
  set -e
  report_rc "scp_supervise" "$scp_rc" || die "scp supervisor failed"
  # Optional host inject of S99 body for unit tests (DEPLOY_S99_BLOB).
  s99_b64=""
  if [[ -n "${DEPLOY_S99_BLOB:-}" && -f "${DEPLOY_S99_BLOB}" ]]; then
    s99_b64=$(base64 -w0 <"$DEPLOY_S99_BLOB" 2>/dev/null || base64 <"$DEPLOY_S99_BLOB" | tr -d '\n')
  fi
  set +e
  ssh_m "set -e
    root='$TARGET_ROOT'
    s99_b64='$s99_b64'
    mkdir -p \"\$root/bin\"
    mv -f /tmp/misterplexd_supervise.deploy.$$ \"\$root/bin/misterplexd_supervise.sh\"
    chmod +x \"\$root/bin/misterplexd_supervise.sh\"
    # Resolve LIVE hook path from S99user USER_SCRIPT= (never hardcode underscore decoy).
    s99_body=''
    if [ -n \"\$s99_b64\" ]; then
      s99_body=\$(printf '%s' \"\$s99_b64\" | base64 -d 2>/dev/null || true)
    elif [ -f /etc/init.d/S99user ]; then
      s99_body=\$(cat /etc/init.d/S99user)
    fi
    hook=''
    if [ -n \"\$s99_body\" ]; then
      hook=\$(printf '%s\n' \"\$s99_body\" | sed -n 's/.*USER_SCRIPT=//p' | head -1 | sed 's/[\"'\'']//g' | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
    fi
    if [ -z \"\$hook\" ]; then
      hook=/media/fat/linux/user-startup.sh
      echo HOOK_RESOLVE_SOURCE=fallback_default
    else
      echo HOOK_RESOLVE_SOURCE=s99user
    fi
    case \"\$hook\" in
      /*) ;;
      *) echo FAIL_HOOK_NOT_ABSOLUTE got=\"\$hook\"; exit 8 ;;
    esac
    # Refuse writing the underscore decoy even if S99 were wrong.
    base=\$(basename \"\$hook\")
    case \"\$base\" in
      _*) echo FAIL_HOOK_IS_DECOY path=\"\$hook\" detail=S99user_must_not_point_at_underscore; exit 8 ;;
    esac
    echo HOOK_LIVE_PATH=\$hook
    mkdir -p \"\$(dirname \"\$hook\")\"
    touch \"\$hook\"
    bak=\${hook}.bak.\$(date -u +%Y%m%dT%H%M%SZ)
    cp -f \"\$hook\" \"\$bak\"
    # Strip ALL MiSTerPlex autostart lines (both roots + bare + supervise).
    # Idempotence must match v1 AND v2 (old bug grepped only misterplex/bin).
    tmp=\$(mktemp)
    grep -vE 'misterplexd_supervise\\.sh|/misterplex/bin/misterplexd|/misterplex_v2/bin/misterplexd' \"\$hook\" >\"\$tmp\" || true
    grep -vE '^# MiSTerPlex (pair autostart|companion)' \"\$tmp\" >\"\$tmp.2\" || true
    mv -f \"\$tmp.2\" \"\$tmp\"
    printf '\\n# MiSTerPlex pair autostart (atomic with core+daemon+conf; do not hand-edit)\\n' >>\"\$tmp\"
    printf 'nohup %s/bin/misterplexd_supervise.sh >>%s/misterplexd_supervise.log 2>&1 &\\n' \"\$root\" \"\$root\" >>\"\$tmp\"
    mv -f \"\$tmp\" \"\$hook\"
    sync
    echo HOOK_BAK=\$bak
    echo HOOK_LINE=\$(grep misterplexd_supervise.sh \"\$hook\" | head -1)
    n=\$(grep -c misterplexd_supervise.sh \"\$hook\" || true)
    if [ \"\$n\" -ne 1 ]; then echo FAIL_HOOK_N=\$n; exit 8; fi
    if [ \"\$root\" = /media/fat/misterplex_v2 ] && grep -qE '/misterplex/bin/misterplexd([^_]|\$)' \"\$hook\"; then
      echo FAIL_HOOK_V1_STILL_PRESENT; exit 8
    fi
    # Bundle match: hook root must equal deploy target root.
    if ! grep -qF \"\$root/bin/misterplexd_supervise.sh\" \"\$hook\"; then
      echo FAIL_HOOK_ROOT_MISMATCH expect=\$root; exit 8
    fi
    echo BOOT_HOOK_OK path=\$hook root=\$root
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
