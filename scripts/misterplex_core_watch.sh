#!/bin/sh
# Watch MiSTer Main's /tmp/CORENAME (and RBFNAME). When the Plex core is loaded,
# ensure misterplexd is running. The RBF itself cannot exec ARM processes — Main
# only publishes the core name; this helper bridges core-load → daemon start.
#
# Install: nohup this from /media/fat/linux/_user-startup.sh (deploy does that).
set -eu

CORENAME_FILE="${CORENAME_FILE:-/tmp/CORENAME}"
RBFNAME_FILE="${RBFNAME_FILE:-/tmp/RBFNAME}"
ROOT="${MISTERPLEX_ROOT:-/media/fat/misterplex}"
BIN="${MISTERPLEXD_BIN:-$ROOT/bin/misterplexd}"
SUP="${MISTERPLEX_SUPERVISE:-$ROOT/bin/misterplexd_supervise.sh}"
WATCHLOG="${MISTERPLEX_WATCHLOG:-$ROOT/misterplex_core_watch.log}"
POLL_S="${MISTERPLEX_WATCH_POLL_S:-2}"
ID="${MISTERPLEX_ID:-misterplex}"
PORT="${MISTERPLEX_PORT:-3005}"
NAME="${MISTERPLEX_NAME:-MiSTerPlex}"
CONF="${MISTERPLEX_CONF:-$ROOT/misterplex.conf}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log() { echo "$(ts) $*" >>"$WATCHLOG"; }

is_plex_core() {
  # CORENAME is typically "Plex"; RBFNAME may be "Plex" or a path basename.
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

daemon_alive() {
  if command -v pidof >/dev/null 2>&1; then
    pidof misterplexd >/dev/null 2>&1 && return 0
  fi
  # Fallback: port probe (busybox wget)
  wget -q -T 1 -O /dev/null "http://127.0.0.1:${PORT}/resources" 2>/dev/null && return 0
  return 1
}

supervise_alive() {
  # Match our supervise script without killing unrelated shells.
  # Never let a vanished /proc/$pid trip set -e.
  if command -v pidof >/dev/null 2>&1; then
    for p in $(pidof sh ash busybox 2>/dev/null || true); do
      [ -r "/proc/$p/cmdline" ] || continue
      cmd=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null || true)
      case "$cmd" in
        *misterplexd_supervise.sh*) return 0 ;;
      esac
    done
  fi
  return 1
}

ensure_daemon() {
  if daemon_alive; then
    return 0
  fi

  if [ ! -x "$BIN" ]; then
    log "ENSURE_FAIL missing $BIN"
    return 1
  fi

  # Prefer a single supervise parent. If it is already alive, wait for backoff
  # respawn — do not start a second misterplexd (double-bind / race).
  if supervise_alive; then
    i=0
    while [ "$i" -lt 15 ]; do
      daemon_alive && { log "ENSURE_OK supervise respawn"; return 0; }
      i=$((i + 1))
      sleep 1
    done
    log "ENSURE_WARN supervise alive but daemon still down after 15s"
    return 1
  fi

  if [ -x "$SUP" ]; then
    log "ENSURE_START supervise=$SUP (core load / daemon down)"
    # Pass identity into supervise child environment.
    MISTERPLEX_ID="$ID" MISTERPLEX_PORT="$PORT" MISTERPLEX_NAME="$NAME" \
      MISTERPLEX_CONF="$CONF" MISTERPLEXD_BIN="$BIN" \
      nohup "$SUP" >>"$WATCHLOG" 2>&1 &
    i=0
    while [ "$i" -lt 8 ]; do
      daemon_alive && { log "ENSURE_OK via supervise"; return 0; }
      i=$((i + 1))
      sleep 1
    done
  fi

  # Last resort: direct spawn only if still nothing answered on the port.
  if ! daemon_alive && ! supervise_alive; then
    log "ENSURE_START direct bin=$BIN"
    nohup "$BIN" --name "$NAME" --id "$ID" --port "$PORT" --conf "$CONF" \
      >>"${MISTERPLEX_LOG:-$ROOT/misterplexd.log}" 2>&1 &
    sleep 1
  fi

  if daemon_alive; then
    log "ENSURE_OK daemon up"
    return 0
  fi
  log "ENSURE_FAIL daemon still down"
  return 1
}

mkdir -p "$ROOT"
log "WATCH_START poll=${POLL_S}s corename=$CORENAME_FILE rbfname=$RBFNAME_FILE"
last_plex=0

# Boot: if Plex already loaded (or always ensure once), bring daemon up.
if plex_loaded; then
  ensure_daemon || true
  last_plex=1
else
  # Still start once at boot so cast discovery works before the core is loaded.
  ensure_daemon || true
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
      log "CORE_PLEX_LEAVE (daemon left running for cast discovery)"
      last_plex=0
    fi
  fi
  sleep "$POLL_S"
done
