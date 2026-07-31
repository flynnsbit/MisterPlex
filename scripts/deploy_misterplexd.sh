#!/usr/bin/env bash
# Deploy static ARM misterplexd to the LIVE MiSTer install root and restart once.
#
# Hard lessons (parent-measured 2026-07-30):
#  1. Rebuilding inside deploy can ship a DIFFERENT md5 than the host-validated
#     artifact (BUILD_ID / flags drift). Default is ship-the-file; rebuild is opt-in.
#  2. Hardcoding /media/fat/misterplex installs to the WRONG root when the live
#     daemon is misterplex_v2. Resolve root from live --conf (or explicit env).
#  3. Starting a second tree without stopping the first leaves n_daemon=2 and a
#     loser with no TCP bind. Stop → copy → single start → assert n_daemon==1
#     and /proc/PID/exe md5 == host artifact.
#
# Host unit tests inject DEPLOY_SSHM / DEPLOY_SCPM (never touch the real box).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/deploy_misterplexd_lib.sh"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
BIN="${DEPLOY_BIN:-$ROOT/build/arm/misterplexd}"
PLAYER_ID="${MISTERPLEX_ID:-misterplex-dev}"
PMS_URL="${PLEX_BASE:-${PMS_URL:-}}"
PORT="${MISTERPLEX_PORT:-3005}"
# Opt-in rebuild only. Default ships the already-built artifact verbatim.
DEPLOY_REBUILD="${DEPLOY_REBUILD:-0}"
# Optional: parent pre-validated md5; refuse to ship anything else.
EXPECT_MD5="${DEPLOY_EXPECT_MD5:-${EXPECT_MD5:-}}"
DEPLOY_SKIP_GEOMETRY_GATE="${DEPLOY_SKIP_GEOMETRY_GATE:-0}"
# Explicit root override (e.g. first install). Otherwise resolved from live daemon.
FORCE_ROOT="${MISTERPLEX_ROOT:-}"

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

# --- host artifact ------------------------------------------------------------
if [[ "$DEPLOY_REBUILD" == "1" ]]; then
  export PATH="${PATH}:${ARM_TOOLCHAIN_BIN:-$HOME/Projects/mistercast-linux/third_party/arm-gnu-toolchain/bin}"
  make -C "$ROOT" arm-plexd
fi

[[ -f "$BIN" ]] || die "missing artifact $BIN (build with make arm-plexd, or set DEPLOY_BIN)"
[[ -x "$BIN" ]] || chmod +x "$BIN" || true

HOST_MD5="$(md5sum "$BIN" | awk '{print $1}')"
echo "deploy: host_artifact=$BIN"
echo "deploy: host_md5=$HOST_MD5"
if [[ -n "$EXPECT_MD5" && "$HOST_MD5" != "$EXPECT_MD5" ]]; then
  die "host md5 $HOST_MD5 != DEPLOY_EXPECT_MD5/EXPECT_MD5 $EXPECT_MD5 (refusing to ship unvalidated binary)"
fi

# --- resolve LIVE install root ------------------------------------------------
resolve_live_root() {
  ssh_m 'bash -s' <<'EOS'
set +e
found=""
n=0
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
  case "$cmd" in
    *plexctl.sh*) continue ;;
    *plexctl_supervise*) continue ;;
    *misterplexd_supervise*) continue ;;
    *dedupe_daemon*) continue ;;
  esac
  case "$cmd" in
    */misterplexd\ *|*/misterplexd)
      ;;
    *) continue ;;
  esac
  n=$((n + 1))
  conf=""
  set -- $cmd
  while [ $# -gt 0 ]; do
    if [ "$1" = "--conf" ]; then
      conf="${2:-}"
      break
    fi
    shift
  done
  if [ -n "$conf" ]; then
    root=$(dirname "$conf")
  else
    binpath=$(tr "\0" "\n" < "$d/cmdline" 2>/dev/null | head -n1)
    root=$(dirname "$(dirname "$binpath")")
  fi
  echo "LIVE_PID=${d#/proc/} ROOT=$root CONF=${conf:-} CMD=$cmd"
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

LIVE_BLOB="$(resolve_live_root)"
echo "$LIVE_BLOB" | sed 's/^/deploy: probe: /'

if echo "$LIVE_BLOB" | grep -q '^MULTI_ROOT'; then
  die "multiple live daemon roots — stop extras before deploy (see probe lines)"
fi

LIVE_ROOT="$(echo "$LIVE_BLOB" | awk -F= '/^ROOT=/{print $2; exit}')"

rr=0
TARGET_ROOT="$(deploy_resolve_target_root "$LIVE_ROOT" "$FORCE_ROOT")" || rr=$?
if [[ "$rr" -eq 2 ]]; then
  die "live root is $LIVE_ROOT but MISTERPLEX_ROOT=$FORCE_ROOT — refusing cross-root deploy (unset override or stop the live daemon)"
elif [[ "$rr" -eq 0 && -n "${TARGET_ROOT:-}" ]]; then
  if [[ -n "$FORCE_ROOT" ]]; then
    echo "deploy: target_root=$TARGET_ROOT (MISTERPLEX_ROOT override)"
  else
    echo "deploy: target_root=$TARGET_ROOT (from live --conf)"
  fi
else
  DETECT="$(ssh_m 'if [ -x /media/fat/misterplex_v2/bin/misterplexd ] || [ -f /media/fat/misterplex_v2/misterplex.conf ]; then echo /media/fat/misterplex_v2; elif [ -d /media/fat/misterplex ]; then echo /media/fat/misterplex; else echo /media/fat/misterplex_v2; fi')"
  TARGET_ROOT="$(echo "$DETECT" | tail -n1 | tr -d '\r')"
  echo "deploy: target_root=$TARGET_ROOT (no live daemon; defaulted)"
fi

[[ -n "$TARGET_ROOT" ]] || die "empty target root"
case "$TARGET_ROOT" in
  /media/fat/misterplex|/media/fat/misterplex_v2) ;;
  *)
    [[ "$TARGET_ROOT" == /* ]] || die "target root must be absolute: $TARGET_ROOT"
    ;;
esac

REMOTE_BIN="$TARGET_ROOT/bin/misterplexd"
REMOTE_CONF="$TARGET_ROOT/misterplex.conf"
REMOTE_LOG="$TARGET_ROOT/misterplexd.log"

# --- stop every daemon/supervisor (cmdline match; no kill -9) -----------------
echo "deploy: stopping all misterplexd + supervisors"
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

# --- install exact bytes to LIVE root only ------------------------------------
echo "deploy: install $HOST_MD5 -> $REMOTE_BIN"
ssh_m "echo DEPLOY_INSTALL_PREP root='$TARGET_ROOT'
mkdir -p '$TARGET_ROOT/bin' '$TARGET_ROOT/scripts'
if [ -f '$REMOTE_BIN' ]; then cp -f '$REMOTE_BIN' '$REMOTE_BIN.prev-deploy'; fi
rm -f '$REMOTE_BIN'"
scp_to "$BIN" "$REMOTE_BIN"

if [[ -f "$ROOT/scripts/plex_browse.sh" ]]; then
  scp_to "$ROOT/scripts/plex_browse.sh" "$TARGET_ROOT/scripts/plex_browse.sh" || true
  [[ -f "$ROOT/scripts/plex_menu.sh" ]] && scp_to "$ROOT/scripts/plex_menu.sh" "$TARGET_ROOT/scripts/plex_menu.sh" || true
fi

# --- start exactly one daemon under TARGET_ROOT -------------------------------
echo "deploy: start single daemon root=$TARGET_ROOT"
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
  sleep 1.2
fi

n=0
pids=""
live_md5=""
live_conf=""
for d in /proc/[0-9]*; do
  [ -r "$d/cmdline" ] || continue
  cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
  case "$cmd" in *plexctl.sh*|*supervise*|*dedupe_daemon*) continue ;; esac
  case "$cmd" in */misterplexd\ *|*/misterplexd) ;; *) continue ;; esac
  p=${d#/proc/}
  n=$((n + 1))
  pids="$pids $p"
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
echo "POST_LIVE_MD5=$live_md5"
echo "POST_LIVE_CONF=$live_conf"
echo "POST_HOST_MD5=$HOST_MD5"
echo "POST_TARGET_ROOT=$TARGET_ROOT"

if [[ "$n" -ne 1 ]]; then
  echo "FAIL n_daemon=$n want=1 pids='$pids'"
  exit 3
fi
if [[ -z "$live_md5" ]]; then
  echo "FAIL empty /proc/PID/exe md5"
  exit 4
fi
if [[ "$live_md5" != "$HOST_MD5" ]]; then
  echo "FAIL live exe md5 $live_md5 != host artifact $HOST_MD5 (ETXTBSY or wrong file shipped)"
  exit 5
fi
case "$live_conf" in
  "$TARGET_ROOT"/*) ;;
  *)
    echo "FAIL live --conf '$live_conf' not under target root $TARGET_ROOT"
    exit 6
    ;;
esac

code=$(wget -q -O /dev/null -S "http://127.0.0.1:${PORT:-3005}/resources" 2>&1 | awk '/HTTP\//{print $2; exit}')
code=${code:-000}
echo "POST_HTTP=$code"
if [[ "$code" != "200" ]]; then
  # curl fallback for hosts without wget -S
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 "http://127.0.0.1:${PORT:-3005}/resources" || echo 000)
    echo "POST_HTTP_CURL=$code"
  fi
fi
if [[ "$code" != "200" ]]; then
  echo "FAIL /resources HTTP $code (daemon up but not healthy)"
  exit 7
fi
echo "DEPLOY_OK root=$TARGET_ROOT md5=$live_md5 n_daemon=1 http=$code"
REMOTE

echo "Deployed misterplexd → $HOST root=$TARGET_ROOT md5=$HOST_MD5 (verified /proc/exe)"

if [[ "$DEPLOY_SKIP_GEOMETRY_GATE" != "1" && -z "${DEPLOY_SSHM:-}" ]]; then
  set +e
  "$ROOT/scripts/check_core_conf_geometry.sh"
  geo_rc=$?
  set -e
  case "$geo_rc" in
    0) echo "core_conf_geometry: PASS" ;;
    77) echo "core_conf_geometry: SKIP-NOT-PASS (rc=77)" >&2 ;;
    *)
      echo "core_conf_geometry: FAIL rc=$geo_rc" >&2
      exit "$geo_rc"
      ;;
  esac
fi
