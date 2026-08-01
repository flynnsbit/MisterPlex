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

# DEPLOY TRAP (parent 2026-07-31 measured): NEVER rename the live binary before
# kill. After `mv misterplexd misterplexd.bak.<md5>`, /proc/PID/exe resolves to
# the .bak path and a `case $exe in *misterplexd)` kill loop matches NOTHING —
# old daemon keeps running; disk looks perfect; live md5 stays old. Sibling of
# ETXTBSY. Rule: stop/kill by /proc/comm+argv0 (and/or captured PIDs) BEFORE any
# rename; verify AFTER by md5sum "$(readlink -f /proc/$pid/exe)". No pgrep on
# device (busybox — missing).
#
# --- stop every daemon/supervisor (no kill -9 storms) --------------------------
# Parent trap: NEVER match cmdline substring "misterplexd" — flock argv contains
# it and yields false PIDs / false 0% CPU. Use /proc/PID/comm + argv0 basename.
# After stop, do not readlink exe of a deleted inode (empty); match on comm/argv0.
echo "deploy: stopping all misterplexd + supervisors (comm/argv0, not cmdline substr)"
set +e
ssh_m 'bash -s' <<'EOS'
set +e
is_daemon_pid() {
  p="$1"
  [ -r "/proc/$p/comm" ] || return 1
  c=$(cat "/proc/$p/comm" 2>/dev/null || true)
  # kernel comm is truncated to 15 chars — misterplexd fits
  if [ "$c" = "misterplexd" ]; then return 0; fi
  [ -r "/proc/$p/cmdline" ] || return 1
  a0=$(tr "\0" "\n" < "/proc/$p/cmdline" 2>/dev/null | head -n1)
  case "$a0" in
    */misterplexd|misterplexd) return 0 ;;
  esac
  return 1
}
is_supervisor_pid() {
  p="$1"
  [ -r "/proc/$p/cmdline" ] || return 1
  cmd=$(tr "\0" " " < "/proc/$p/cmdline" 2>/dev/null) || return 1
  case "$cmd" in *plexctl.sh*) return 1 ;; esac
  # Match supervise SCRIPT path tokens, not bare "misterplexd"
  case "$cmd" in
    *misterplexd_supervise.sh*|*plexctl_supervise.sh*|*dedupe_daemon.sh*) return 0 ;;
  esac
  return 1
}
list_targets() {
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p=${d#/proc/}
    if is_daemon_pid "$p" || is_supervisor_pid "$p"; then
      echo "$p"
    fi
  done
}
for p in $(list_targets); do
  kill "$p" 2>/dev/null || true
done
i=0
while [ "$i" -lt 40 ]; do
  left=0
  for p in $(list_targets); do left=$((left + 1)); done
  [ "$left" -eq 0 ] && break
  i=$((i + 1))
  sleep 0.25
done
left=0
for p in $(list_targets); do
  left=$((left + 1))
  c=$(cat /proc/$p/comm 2>/dev/null || echo "?")
  a0=$(tr "\0" "\n" < /proc/$p/cmdline 2>/dev/null | head -n1)
  echo "STILL_UP pid=$p comm=$c argv0=$a0"
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

# --- install exact bytes (stage then mv; never cp over running binary) --------
echo "deploy: install host_md5=$HOST_MD5 -> $REMOTE_BIN (stage+mv; no rebuild)"
# Content-addressed archive of outgoing daemon so atomic pair rollback can find
# the previous pin. Parent: ETXTBSY on cp-over-running silently leaves old live.
# stderr is NOT suppressed on deploy steps.
STAGED_REMOTE="/tmp/misterplexd.deploy.$$"
set +e
ssh_m "echo DEPLOY_INSTALL_PREP root='$TARGET_ROOT'
set -e
mkdir -p '$TARGET_ROOT/bin' '$TARGET_ROOT/scripts'
if [ -f '$REMOTE_BIN' ]; then
  om=\$(md5sum '$REMOTE_BIN' | awk '{print \$1}')
  cp -f '$REMOTE_BIN' '$REMOTE_BIN.prev-deploy'
  if [ -n "\$om" ]; then
    arch='$REMOTE_BIN.'.\${om:0:8}.bak
    if [ ! -f "\$arch" ]; then
      cp -f '$REMOTE_BIN' "\$arch"
      echo "ARCHIVED_DAEMON \$arch"
    else
      echo "ARCHIVE_DAEMON_SKIP \$arch"
    fi
  fi
fi
echo PREP_OK"
prep_rc=$?
set -e
report_rc "install_prep" "$prep_rc" || die "install prep failed"

set +e
scp_to "$BIN" "$STAGED_REMOTE"
scp_rc=$?
set -e
report_rc "scp_stage" "$scp_rc" || die "scp to stage failed (stderr above; not suppressed)"

set +e
ssh_m "set -e
  staged='$STAGED_REMOTE'
  dst='$REMOTE_BIN'
  host_want='$HOST_MD5'
  sm=\$(md5sum "\$staged" | awk '{print \$1}')
  echo STAGE_MD5=\$sm
  if [ "\$sm" != "\$host_want" ]; then
    echo "FAIL stage md5 \$sm != host \$host_want"
    rm -f "\$staged"
    exit 7
  fi
  # rename semantics replace destination; daemon must already be stopped
  mv -f "\$staged" "\$dst"
  chmod 755 "\$dst"
  sync
  dm=\$(md5sum "\$dst" | awk '{print \$1}')
  echo DISK_MD5=\$dm
  if [ "\$dm" != "\$host_want" ]; then
    echo "FAIL disk md5 \$dm != host \$host_want after mv"
    exit 7
  fi
  echo INSTALL_OK
"
inst_rc=$?
set -e
report_rc "install_mv" "$inst_rc" || die "stage+mv install failed (rc=$inst_rc)"

set +e
DISK_MD5="$(ssh_m "md5sum '$REMOTE_BIN'" | awk '{print $1}')"
disk_rc=$?
set -e
report_rc "disk_md5_probe" "$disk_rc" || die "disk md5 probe failed"
echo "deploy: disk_md5=$DISK_MD5"
if [[ "$DISK_MD5" != "$HOST_MD5" ]]; then
  die "disk md5 $DISK_MD5 != host md5 $HOST_MD5 (install corrupted; not restarting)"
fi
report_rc "disk_md5_match" 0

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
