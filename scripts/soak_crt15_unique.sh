#!/usr/bin/env bash
# CRT 15 kHz unique-frame soak.
#
# Unique = hw_presents (fabric PLXD swap count) / wall elapsed.
# Soft-skip and hw_presents=unavailable are not PASS.
# HDMI grabber frames are not the CRT proof.
#
# Env:
#   SOAK_S           window seconds (default 600)
#   MIN_UNIQUE_FPS   gate (default 23.5)
#   MIN_ELAPSED_S    minimum wall (default 580)
#   SOAK_STATS_FILE  local misterplexd.log (no device; preferred for replay)
#   SOAK_LIVE        1 = poll live daemon (opt-in; this worker never sets it)
#   MISTER_HOST      default 192.168.1.183 (used only if SOAK_LIVE=1)
#   MISTERPLEX_PORT  default 3005
#   MISTERPLEX_LOG   remote log (default /media/fat/misterplex/misterplexd.log)
#   SOAK_SAMPLE_S    live poll interval (default 5)
#
# rc=0  unique/elapsed >= MIN_UNIQUE_FPS and elapsed >= MIN_ELAPSED_S
# rc=1  rate or elapsed fail (honest FAIL)
# rc=2  daemon missing / hw_presents=unavailable — refuse PASS
set -euo pipefail

SOAK_S="${SOAK_S:-600}"
MIN_UNIQUE_FPS="${MIN_UNIQUE_FPS:-23.5}"
MIN_ELAPSED_S="${MIN_ELAPSED_S:-580}"
STATS_FILE="${SOAK_STATS_FILE:-}"
LIVE="${SOAK_LIVE:-0}"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
PORT="${MISTERPLEX_PORT:-3005}"
REMOTE_LOG="${MISTERPLEX_LOG:-/media/fat/misterplex/misterplexd.log}"
SAMPLE_S="${SOAK_SAMPLE_S:-5}"

log() { printf '[soak_crt15] %s\n' "$*"; }

refuse() {
  log "REFUSE: $* — not PASS"
  echo "UNIQUE fps=NA frames=NA elapsed=NA src=unavailable"
  echo "RESULT=REFUSE"
  exit 2
}

fail_rate() {
  log "FAIL: $*"
  echo "RESULT=UNIQUE_FAIL"
  exit 1
}

# Parse one daemon stats line. Sets: P_FRAMES P_HW P_WALL P_UNAVAIL
# hw_presents=unavailable or missing hw_presents → P_UNAVAIL=1
parse_stats_line() {
  local line="$1"
  P_FRAMES=""
  P_HW=""
  P_WALL=""
  P_UNAVAIL=0
  [[ -n "$line" ]] || return 1
  if echo "$line" | grep -q 'hw_presents=unavailable'; then
    P_UNAVAIL=1
  fi
  P_FRAMES=$(echo "$line" | sed -n 's/.*[[:space:]]frames=\([0-9][0-9]*\).*/\1/p' | tail -1)
  P_HW=$(echo "$line" | sed -n 's/.*hw_presents=\([0-9][0-9]*\).*/\1/p' | tail -1)
  P_WALL=$(echo "$line" | sed -n 's/.*wall_s=\([0-9][0-9]*\(\.[0-9]*\)\?\).*/\1/p' | tail -1)
  if [[ "$P_UNAVAIL" -eq 1 || -z "$P_HW" ]]; then
    P_UNAVAIL=1
    return 1
  fi
  return 0
}

latest_stats_from_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep 'media: frames=' "$f" 2>/dev/null | tail -1 || true
}

first_stats_from_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep 'media: frames=' "$f" 2>/dev/null | head -1 || true
}

probe_daemon_http() {
  local dest="$1"
  curl -fsS --connect-timeout 3 --max-time 6 \
    "http://${dest}:${PORT}/resources" >/dev/null 2>&1
}

fetch_remote_log_tail() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
    "${USER}@${HOST}" "tail -n 400 '$REMOTE_LOG' 2>/dev/null || true"
}

# --- collect samples ----------------------------------------------------------
START_LINE=""
END_LINE=""
ELAPSED=""
SRC=""

if [[ -n "$STATS_FILE" ]]; then
  SRC="file:$STATS_FILE"
  [[ -f "$STATS_FILE" ]] || refuse "SOAK_STATS_FILE missing: $STATS_FILE"
  START_LINE=$(first_stats_from_file "$STATS_FILE")
  END_LINE=$(latest_stats_from_file "$STATS_FILE")
  [[ -n "$END_LINE" ]] || refuse "no media: frames= lines in $STATS_FILE (daemon stats missing)"
elif [[ "$LIVE" == "1" ]]; then
  SRC="live:${HOST}:${PORT}"
  log "LIVE poll host=$HOST soak_s=$SOAK_S (opt-in)"
  if ! probe_daemon_http "$HOST"; then
    refuse "daemon missing at http://${HOST}:${PORT}/resources"
  fi
  TMP_LIVE="$(mktemp /tmp/misterplex-soak-crt15.XXXXXX)"
  trap 'rm -f "$TMP_LIVE"' EXIT
  fetch_remote_log_tail >"$TMP_LIVE" || true
  START_LINE=$(latest_stats_from_file "$TMP_LIVE")
  T0=$(date +%s)
  sleep "$SOAK_S"
  T1=$(date +%s)
  ELAPSED=$((T1 - T0))
  fetch_remote_log_tail >"$TMP_LIVE" || true
  END_LINE=$(latest_stats_from_file "$TMP_LIVE")
  [[ -n "$END_LINE" ]] || refuse "no media: frames= lines on live log (daemon stats missing)"
  if ! probe_daemon_http "$HOST"; then
    refuse "daemon disappeared during soak"
  fi
else
  # Default: do not touch the lab box. Require a log or explicit SOAK_LIVE=1.
  if probe_daemon_http "127.0.0.1"; then
    refuse "local daemon on :${PORT} is not a CRT soak source; set SOAK_STATS_FILE or SOAK_LIVE=1"
  fi
  refuse "daemon missing (no SOAK_STATS_FILE; SOAK_LIVE!=1). Soft-skip ≠ PASS"
fi

if echo "$END_LINE" | grep -q 'hw_presents=unavailable'; then
  refuse "hw_presents=unavailable"
fi

parse_stats_line "$END_LINE" || refuse "hw_presents missing or unavailable on last stats line"

END_HW="$P_HW"
END_FRAMES="${P_FRAMES:-0}"
END_WALL="${P_WALL:-}"

START_HW=0
START_WALL=""
if [[ -n "$START_LINE" && "$START_LINE" != "$END_LINE" ]]; then
  if parse_stats_line "$START_LINE"; then
    START_HW="$P_HW"
    START_WALL="${P_WALL:-}"
  fi
fi

UNIQUE=$((END_HW - START_HW))
if [[ "$UNIQUE" -lt 0 ]]; then
  UNIQUE="$END_HW"
fi

if [[ -z "${ELAPSED:-}" ]]; then
  if [[ -n "$END_WALL" && -n "$START_WALL" && "$START_LINE" != "$END_LINE" ]]; then
    ELAPSED=$(awk -v a="$END_WALL" -v b="$START_WALL" 'BEGIN{d=a-b; if(d<0)d=a; printf "%.3f", d}')
  elif [[ -n "$END_WALL" ]]; then
    ELAPSED="$END_WALL"
  else
    ELAPSED="$SOAK_S"
  fi
fi

FPS=$(awk -v u="$UNIQUE" -v e="$ELAPSED" 'BEGIN{
  if (e+0 <= 0) { print "0"; exit }
  printf "%.4f", u/e
}')

printf 'UNIQUE fps=%s frames=%s elapsed=%s src=%s arm_frames=%s\n' \
  "$FPS" "$UNIQUE" "$ELAPSED" "${SRC:-file}" "$END_FRAMES"
printf 'GATE min_fps=%s min_elapsed=%s hw_presents_end=%s\n' \
  "$MIN_UNIQUE_FPS" "$MIN_ELAPSED_S" "$END_HW"

awk -v fps="$FPS" -v e="$ELAPSED" -v minf="$MIN_UNIQUE_FPS" -v mine="$MIN_ELAPSED_S" 'BEGIN{
  if (e+0 < mine+0) exit 1
  if (fps+0 < minf+0) exit 1
  exit 0
}' || fail_rate "unique/elapsed=$FPS < $MIN_UNIQUE_FPS or elapsed=$ELAPSED < $MIN_ELAPSED_S"

echo "RESULT=UNIQUE_OK"
exit 0
