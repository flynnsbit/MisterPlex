#!/bin/sh
# Bridge Main's /tmp/CORENAME → one matching misterplexd.
#
# The RBF cannot exec Linux. This watcher is the stand-in:
#   Plex loaded  → start the daemon that pairs with the live Plex.rbf md5
#   Plex left / reset → stop supervise + daemon (no orphans, no second copy)
# A second watcher exits on the mkdir lock.
#
# Glass pin /tmp/misterplex-live-glass comes from rbf_daemon_pairs.txt column 3
# (true480|l4|crt240p15|crt480i). Two-column v0.7.0 lines stay valid.
set -eu

CORENAME_FILE="${CORENAME_FILE:-/tmp/CORENAME}"
RBFNAME_FILE="${RBFNAME_FILE:-/tmp/RBFNAME}"
ROOT="${MISTERPLEX_ROOT:-/media/fat/misterplex}"
PAIRS="${MISTERPLEX_PAIRS:-$ROOT/rbf_daemon_pairs.txt}"
DEFAULT_BIN="${MISTERPLEXD_BIN:-$ROOT/bin/misterplexd}"
SUP="${MISTERPLEX_SUPERVISE:-$ROOT/bin/misterplexd_supervise.sh}"
WATCHLOG="${MISTERPLEX_WATCHLOG:-$ROOT/misterplex_core_watch.log}"
POLL_S="${MISTERPLEX_WATCH_POLL_S:-2}"
ID="${MISTERPLEX_ID:-misterplex-dev}"
PORT="${MISTERPLEX_PORT:-3005}"
NAME="${MISTERPLEX_NAME:-MiSTerPlex}"
CONF="${MISTERPLEX_CONF:-$ROOT/misterplex.conf}"
LOCKDIR="${MISTERPLEX_WATCH_LOCK:-/tmp/misterplex-watch.lock}"
LIVE_RBF="${MISTERPLEX_LIVE_RBF:-/media/fat/_Utility/Plex.rbf}"
LIVE_GLASS="${MISTERPLEX_LIVE_GLASS:-/tmp/misterplex-live-glass}"

mkdir -p "$ROOT" "$(dirname "$WATCHLOG")" 2>/dev/null || true

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >>"$WATCHLOG"; }

# Pair/glass helpers live in rbf_pair.sh (this script is not sourcable).
_rbf_pair_loaded=0
_script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
for _c in \
  "${MISTERPLEX_RBF_PAIR_LIB:-}" \
  "$_script_dir/rbf_pair.sh" \
  "$_script_dir/lib/rbf_pair.sh" \
  "$ROOT/lib/rbf_pair.sh" \
  "$_script_dir/../lib/rbf_pair.sh" \
  "$_script_dir/../scripts/lib/rbf_pair.sh"
do
  if [ -n "${_c:-}" ] && [ -f "$_c" ]; then
    # shellcheck disable=SC1090
    . "$_c"
    _rbf_pair_loaded=1
    break
  fi
done
if [ "$_rbf_pair_loaded" -ne 1 ]; then
  echo "misterplex_core_watch: missing rbf_pair.sh" >&2
  exit 1
fi

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null && [ "$oldpid" != "$$" ]; then
    echo "$(ts) WATCH_DUP exit — lock held by pid=$oldpid" >>"$WATCHLOG"
    exit 0
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR"
fi
echo $$ >"$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

is_plex_core() {
  name=$(tr -d '\000\r\n' <"$1" 2>/dev/null || true)
  rbf_pair_is_plex_name "$name"
}

plex_loaded() {
  if [ -f "$CORENAME_FILE" ] && is_plex_core "$CORENAME_FILE"; then
    return 0
  fi
  if [ -f "$RBFNAME_FILE" ] && is_plex_core "$RBFNAME_FILE"; then
    return 0
  fi
  return 1
}

daemon_count() {
  ps w | awk '/misterplexd.*--name/ && !/awk/ {c++} END{print c+0}'
}

supervise_count() {
  ps w | awk '/misterplexd_supervise\.sh/ && !/awk/ {c++} END{print c+0}'
}

kill_pids() {
  # $1 = awk pattern
  for p in $(ps w | awk "$1"' && !/awk/ {print $1}'); do
    kill "$p" 2>/dev/null || true
  done
}

stop_plex_arm() {
  # Supervise first so it cannot respawn while we kill the child.
  kill_pids '/misterplexd_supervise\.sh/'
  sleep 0.2
  kill_pids '/[m]isterplexd --/'
  sleep 0.3
  kill_pids '/misterplexd_supervise\.sh/'
  kill_pids '/[m]isterplexd --/'
  # leftover ffmpeg from a torn session
  kill_pids '/[f]fmpeg /'
  rm -rf /tmp/misterplexd-supervise.lock
  log "ARM_STOP daemons=$(daemon_count) supervise=$(supervise_count)"
}

resolve_loaded_rbf() {
  raw=$(tr -d '\000\r\n' <"$RBFNAME_FILE" 2>/dev/null || true)
  base=$(echo "$raw" | sed 's|.*/||; s|\.rbf$||; s|\.RBF$||')
  [ -n "$base" ] || base=Plex
  for cand in \
    "/media/fat/_Utility/${base}.rbf" \
    "/media/fat/${base}.rbf" \
    "$LIVE_RBF" \
    /media/fat/Plex.rbf
  do
    if [ -f "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  echo "$LIVE_RBF"
}

select_bin_for_live_rbf() {
  rbf=$(resolve_loaded_rbf)
  BIN="$DEFAULT_BIN"
  sum="missing"
  glass=$(rbf_pair_default_glass)
  rbf_pair_hit=0
  rbf_pair_bin=$DEFAULT_BIN
  rbf_pair_glass=$glass
  if [ -f "$rbf" ]; then
    sum=$(md5sum "$rbf" | awk '{print $1}')
    rbf_pair_lookup "$PAIRS" "$sum" "$DEFAULT_BIN"
    if [ "${rbf_pair_hit:-0}" -eq 1 ] && [ -x "$rbf_pair_bin" ]; then
      BIN=$rbf_pair_bin
    fi
    glass=$rbf_pair_glass
  fi
  rbf_pair_write_glass "$glass" "$LIVE_GLASS"
  if [ "${rbf_pair_hit:-0}" -eq 1 ] && [ -x "${rbf_pair_bin:-}" ]; then
    log "PAIR_OK file=$rbf rbf=$sum bin=$BIN glass=$glass"
  elif [ -f "$rbf" ]; then
    log "PAIR_DEFAULT file=$rbf rbf=$sum bin=$BIN glass=$glass"
  else
    log "PAIR_DEFAULT no live rbf bin=$BIN glass=$glass"
  fi
  echo "$BIN"
}

ensure_daemon() {
  BIN=$(select_bin_for_live_rbf)
  n=$(daemon_count)
  if [ "$n" -gt 1 ]; then
    log "ENSURE_CULL extras daemons=$n"
    stop_plex_arm
    n=0
  fi
  if [ "$n" -eq 1 ]; then
    return 0
  fi
  if [ ! -x "$BIN" ]; then
    log "ENSURE_FAIL missing $BIN"
    return 1
  fi
  if [ "$(supervise_count)" -gt 0 ]; then
    i=0
    while [ "$i" -lt 8 ]; do
      [ "$(daemon_count)" -eq 1 ] && { log "ENSURE_OK supervise respawn"; return 0; }
      i=$((i + 1))
      sleep 1
    done
    log "ENSURE_WARN supervise up but no single daemon — restarting"
    stop_plex_arm
  fi
  RUN="$ROOT/bin/misterplexd"
  if [ "$BIN" != "$RUN" ] && [ -x "$BIN" ]; then
    src=$(md5sum "$BIN" | awk '{print $1}')
    dst=$(md5sum "$RUN" 2>/dev/null | awk '{print $1}')
    if [ "$src" != "$dst" ]; then
      cp -f "$BIN" "$RUN.tmp" && mv -f "$RUN.tmp" "$RUN"
      chmod +x "$RUN"
      log "PAIR_INSTALL $BIN -> $RUN md5=$src"
    fi
    BIN="$RUN"
  fi
  log "ENSURE_START supervise=$SUP bin=$BIN"
  # 720p24 identity path: inproc is size-ok only at 1280×720 (glass=l4).
  # select_bin runs in $() so rbf_pair_glass is not visible here — read the pin.
  inproc=
  _glass=$(tr -d '\r\n' <"$LIVE_GLASS" 2>/dev/null || true)
  case "$_glass" in
    l4|L4) inproc=1 ;;
  esac
  MISTERPLEX_ID="$ID" MISTERPLEX_PORT="$PORT" MISTERPLEX_NAME="$NAME" \
    MISTERPLEX_CONF="$CONF" MISTERPLEXD_BIN="$BIN" \
    MPX_INPROC_DECODE="${inproc:-}" \
    nohup "$SUP" >>"$WATCHLOG" 2>&1 &
  i=0
  while [ "$i" -lt 8 ]; do
    [ "$(daemon_count)" -eq 1 ] && { log "ENSURE_OK via supervise"; return 0; }
    i=$((i + 1))
    sleep 1
  done
  log "ENSURE_FAIL daemon_count=$(daemon_count)"
  return 1
}

log "WATCH_START poll=${POLL_S}s id=$ID (stop daemon when Plex unloads)"

# Drop any leftover doubles from a previous session, then match CORENAME.
stop_plex_arm
last_plex=0
if plex_loaded; then
  ensure_daemon || true
  last_plex=1
else
  log "CORE_NOT_PLEX — ARM left down until Plex loads"
fi

while true; do
  if plex_loaded; then
    if [ "$last_plex" -eq 0 ]; then
      log "CORE_PLEX_ENTER name=$(tr -d '\000\r\n' <"$CORENAME_FILE" 2>/dev/null || echo '?')"
      last_plex=1
    fi
    ensure_daemon || true
  else
    if [ "$last_plex" -eq 1 ]; then
      log "CORE_PLEX_LEAVE — stopping daemon (RBF no longer on glass)"
      last_plex=0
      stop_plex_arm
    fi
  fi
  sleep "$POLL_S"
done
