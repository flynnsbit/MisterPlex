#!/bin/sh
# Bridge Main's /tmp/CORENAME → one matching misterplexd.
#
# Pair by live Plex*.rbf md5 (rbf_daemon_pairs.txt). The RBF cannot exec Linux.
#   Plex loaded  → start the daemon that pairs with the live RBF md5
#   Plex left / reset → stop supervise + daemon (no orphans, no second copy)
# A second watcher exits on the mkdir lock.
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

GOLD_480P=07f54d9f8f0eda2fe75d9cc314f6de54
GOLD_720P=03f1b95ac67a568f24193234ea8cb072

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*" >>"$WATCHLOG"; }

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
  name=$(echo "$name" | sed 's|.*/||; s|\.rbf$||; s|\.RBF$||')
  case "$name" in
    [Pp]lex|[Pp]lex_*|[Pp]lex-* ) return 0 ;;
    *) return 1 ;;
  esac
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
  for p in $(ps w | awk "$1"' && !/awk/ {print $1}'); do
    kill "$p" 2>/dev/null || true
  done
}

stop_plex_arm() {
  kill_pids '/misterplexd_supervise\.sh/'
  sleep 0.2
  kill_pids '/[m]isterplexd --/'
  sleep 0.3
  kill_pids '/misterplexd_supervise\.sh/'
  kill_pids '/[m]isterplexd --/'
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

glass_for_md5() {
  case "$1" in
    "$GOLD_720P") echo L4 ;;
    "$GOLD_480P") echo true480 ;;
    *) echo crt15 ;;
  esac
}

select_bin_for_live_rbf() {
  rbf=$(resolve_loaded_rbf)
  BIN="$DEFAULT_BIN"
  sum="missing"
  if [ -f "$rbf" ]; then
    sum=$(md5sum "$rbf" | awk '{print $1}')
    if [ -f "$PAIRS" ]; then
      pair=$(awk -v s="$sum" '$1==s && $1 !~ /^#/ && $1 !~ /^TBD/ {print $2; exit}' "$PAIRS")
      if [ -n "${pair:-}" ] && [ -x "$pair" ]; then
        BIN="$pair"
        echo "$(glass_for_md5 "$sum")" > /tmp/misterplex-live-glass
        log "PAIR_OK file=$rbf rbf=$sum bin=$BIN glass=$(cat /tmp/misterplex-live-glass)"
        echo "$BIN"
        return 0
      fi
    fi
    log "PAIR_DEFAULT file=$rbf rbf=$sum bin=$BIN"
  else
    log "PAIR_DEFAULT no live rbf bin=$BIN"
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
  inproc=
  rbf=$(resolve_loaded_rbf)
  if [ -f "$rbf" ]; then
    sum=$(md5sum "$rbf" | awk '{print $1}')
    if [ "$sum" = "$GOLD_720P" ]; then
      inproc=1
    fi
  fi
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

mkdir -p "$ROOT"
log "WATCH_START poll=${POLL_S}s id=$ID (stop daemon when Plex unloads)"

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
