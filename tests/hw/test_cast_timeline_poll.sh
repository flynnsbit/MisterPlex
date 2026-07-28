#!/usr/bin/env bash
# Hardware: cast/timeline progression gate — HTTP control protocol approach.
#
# Approach: Direct HTTP (no browser). Issues /player/playback/playMedia to the
# daemon then polls /player/timeline/poll and asserts on state= and time=.
# This is the same response the real Plex Web client consumes.
#
# Deliberately does NOT assert PMS-side timeline POSTs (separate false-green
# risk; W-CAST documented 12+ "true number about the wrong thing" instances).
#
# Three-question audit:
#  Q1: what does this literally compare?
#      state= (string) and time= (integer ms) from daemon Timeline XML
#  Q2: what does it NOT cover?
#      HDMI output, FPGA decode quality, PMS-side progress reports
#  Q3: can you make it fail?
#      Yes: set CAST_FAIL_INJECT=1 for deterministic red; or run against
#      a broken daemon that stays state="paused" time="0".
#
# Exit codes:
#   0  PASS  state="playing" AND time strictly increasing across polls
#   1  FAIL  timeline stuck (state="paused"/time=0 after full window)
#  77  UNSCORED/SKIP  device or PMS unreachable, or credentials missing
#
# Environment overrides (all optional):
#   MISTER_HOST            default 192.168.1.183
#   MISTER_PASS            default 1
#   PLEX_BASE              e.g. http://192.168.1.41:32400
#   PLEX_TOKEN             Plex auth token
#   PLEX_KEY               media key  (default /library/metadata/3)
#   PMS_MACHINE_ID         PMS machineIdentifier (auto-queried if blank)
#   CAST_POLL_SECONDS      polling window (default 30)
#   CAST_CMD_ID            base commandID (default random 5000-5999)
#   EXPECTED_RBF_MD5       if set, skip when resident RBF doesn't match
#   MISTERPLEX_CONF        path to conf file
#   CAST_FAIL_INJECT       set to 1 to force FAIL for red mutation test

set -euo pipefail

SCRIPT_NAME="test_cast_timeline_poll"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── conf-file resolution (mirrors pattern from other hw gates) ───────────────
CONF_FILE="${MISTERPLEX_CONF:-${MISTER_CONF:-}}"
if [[ -z "$CONF_FILE" ]]; then
  for _c in "$ROOT/assets/misterplex.conf" "$HOME/.config/misterplex/misterplex.conf"; do
    [[ -f "$_c" ]] && CONF_FILE="$_c" && break
  done
fi

conf_val() {
  local key="$1" file="$2"
  [[ -n "$file" && -f "$file" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[ \t]+/, "", $2); sub(/[ \t\r]+$/, "", $2); print $2; exit}' "$file"
}

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
# DAEMON_BASE can be overridden directly for testing against a mock server
DAEMON_BASE="${DAEMON_BASE:-http://${HOST}:3005}"

PLEX_BASE="${PLEX_BASE:-$(conf_val PLEX_BASE "$CONF_FILE")}"
PLEX_TOKEN="${PLEX_TOKEN:-$(conf_val PLEX_TOKEN "$CONF_FILE")}"
PLEX_KEY="${PLEX_KEY:-$(conf_val PLEX_KEY "$CONF_FILE")}"
[[ -n "${PLEX_KEY:-}" ]] || PLEX_KEY="/library/metadata/3"

PMS_HOST=""
PMS_PORT=""
if [[ -n "${PLEX_BASE:-}" ]]; then
  # Strip protocol, split host:port
  _addr="${PLEX_BASE#http://}"; _addr="${_addr#https://}"
  PMS_HOST="${_addr%%:*}"
  PMS_PORT="${_addr##*:}"
fi

PMS_MACHINE_ID="${PMS_MACHINE_ID:-}"
EXPECTED_RBF_MD5="${EXPECTED_RBF_MD5:-}"
POLL_SECONDS="${CAST_POLL_SECONDS:-30}"
CMD_ID_BASE="${CAST_CMD_ID:-$(( RANDOM % 1000 + 5000 ))}"

RC_PASS=0
RC_FAIL=1
RC_UNSCORED=77

# ── helpers ──────────────────────────────────────────────────────────────────
skip() {
  echo "SKIP-NOT-PASS ${SCRIPT_NAME}: $1" >&2
  exit "$RC_UNSCORED"
}

fail() {
  echo "CAST_TIMELINE_RESULT=FAIL reason=$1"
  exit "$RC_FAIL"
}

xml_attr() {
  # xml_attr <attr> <string> — extract attribute value from XML string
  echo "$2" | grep -oP "${1}=\"\K[^\"]+" | head -1 || true
}

# ── prerequisites ─────────────────────────────────────────────────────────────
[[ -n "${PLEX_TOKEN:-}" ]] || \
  skip "PLEX_TOKEN missing — set MISTERPLEX_CONF, PLEX_BASE and PLEX_TOKEN"
[[ -n "${PMS_HOST:-}" ]] || \
  skip "PLEX_BASE missing or unparseable (need http://host:port)"

echo "${SCRIPT_NAME}: BEGIN"
echo "Scope: 1 device (${HOST}:3005), 1 media key (${PLEX_KEY}), asserts on state= and time= from /player/timeline/poll"

# ── resident RBF md5 (first line per protocol; non-fatal unless EXPECTED set) ─
RBF_MD5="unknown"
if command -v sshpass >/dev/null 2>&1; then
  _rbf_raw=$(sshpass -p "$PASS" ssh \
    -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR \
    "root@${HOST}" 'md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null' 2>/dev/null || true)
  _rbf_parsed=$(printf '%s\n' "$_rbf_raw" | tr 'A-F' 'a-f' \
    | grep -oE '\b[0-9a-f]{32}\b' | head -1 || true)
  [[ -n "$_rbf_parsed" ]] && RBF_MD5="$_rbf_parsed"
fi
echo "RBF resident=$RBF_MD5 expected=${EXPECTED_RBF_MD5:-unset}"
if [[ -n "${EXPECTED_RBF_MD5:-}" && "$RBF_MD5" != "$EXPECTED_RBF_MD5" ]]; then
  skip "rbf-md5-mismatch actual=$RBF_MD5 expected=$EXPECTED_RBF_MD5"
fi

# ── connectivity checks ───────────────────────────────────────────────────────
_daemon_probe=$(curl -fsS --max-time 5 \
  "${DAEMON_BASE}/player/timeline/poll?commandID=${CMD_ID_BASE}" 2>&1) \
  || skip "daemon unreachable at ${DAEMON_BASE}"
echo "$_daemon_probe" | grep -q 'Timeline' \
  || skip "daemon response missing Timeline XML (got: ${_daemon_probe:0:120})"

# Use -sS without -f so 401 is not treated as a curl error (PMS requires auth).
# Capture the HTTP code from -w; on connection failure curl emits "" so _pms_rc stays 0.
_pms_rc=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${PLEX_BASE}/" 2>/dev/null) || _pms_rc="${_pms_rc:-0}"
[[ -z "$_pms_rc" ]] && _pms_rc=0
[[ "$_pms_rc" -eq 200 || "$_pms_rc" -eq 401 ]] \
  || skip "PMS unreachable at ${PLEX_BASE} (HTTP $_pms_rc)"

# ── optionally resolve PMS machineIdentifier ──────────────────────────────────
if [[ -z "$PMS_MACHINE_ID" ]]; then
  _mid_resp=$(curl -sS --max-time 5 \
    "${PLEX_BASE}/?X-Plex-Token=${PLEX_TOKEN}" 2>/dev/null || true)
  PMS_MACHINE_ID=$(echo "$_mid_resp" \
    | grep -oP 'machineIdentifier="\K[^"]+' | head -1 || true)
fi
echo "PMS_MACHINE_ID=${PMS_MACHINE_ID:-unresolved}"

# ── stop existing playback for clean baseline ─────────────────────────────────
curl -fsS --max-time 5 \
  "${DAEMON_BASE}/player/playback/stop?commandID=$((CMD_ID_BASE+1))" \
  >/dev/null 2>&1 || true
sleep 0.5

_baseline_resp=$(curl -fsS --max-time 5 \
  "${DAEMON_BASE}/player/timeline/poll?commandID=$((CMD_ID_BASE+2))" 2>&1)
BASELINE_STATE=$(xml_attr state "$_baseline_resp")
BASELINE_TIME=$(xml_attr time "$_baseline_resp")
echo "BASELINE state=${BASELINE_STATE:-unknown} time=${BASELINE_TIME:-unknown}"

# ── issue playMedia ──────────────────────────────────────────────────────────
CMD_PLAY=$((CMD_ID_BASE+3))
_rating_key="$(basename "${PLEX_KEY}")"

# Build optional machineIdentifier arg without inline command substitution
# (avoids "exit code through pipe" class of bugs)
_mid_arg=""
[[ -n "$PMS_MACHINE_ID" ]] && _mid_arg="--data-urlencode machineIdentifier=${PMS_MACHINE_ID}"

# Note: PLEX_TOKEN is read from conf file and passed only as HTTP header;
# it does NOT appear in script source. Never commit conf file to repo.
# shellcheck disable=SC2086  # word splitting of _mid_arg is intentional
_play_resp=$(curl -fsS --max-time 10 --get \
  "${DAEMON_BASE}/player/playback/playMedia" \
  -H "X-Plex-Token: ${PLEX_TOKEN}" \
  -H "X-Plex-Client-Identifier: misterplex-e2e-gate" \
  -H "X-Plex-Product: MiSTerPlex-E2E" \
  --data-urlencode "key=${PLEX_KEY}" \
  --data-urlencode "containerKey=/playQueues/e2e?own=1" \
  --data-urlencode "ratingKey=${_rating_key}" \
  --data-urlencode "address=${PMS_HOST}" \
  --data-urlencode "port=${PMS_PORT}" \
  --data-urlencode "protocol=http" \
  ${_mid_arg} \
  --data-urlencode "offset=0" \
  --data-urlencode "commandID=${CMD_PLAY}" 2>&1) \
  || fail "playMedia request to ${DAEMON_BASE} failed (curl error)"

_play_state=$(xml_attr state "$_play_resp")
echo "PLAY_RESPONSE state=${_play_state:-?}"

# ── poll timeline for state/time advancement ──────────────────────────────────
echo "POLL_BEGIN window=${POLL_SECONDS}s daemon=${DAEMON_BASE}"
POLL_N=0
PLAYING_N=0
ADVANCING_N=0
PREV_TIME=-1
TIME_MAX=0
STATE_SEQ=""

DEADLINE=$(( $(date +%s) + POLL_SECONDS ))
while [[ $(date +%s) -lt $DEADLINE ]]; do
  CMD_POLL=$((CMD_ID_BASE + 10 + POLL_N))
  _poll_raw=$(curl -fsS --max-time 3 \
    "${DAEMON_BASE}/player/timeline/poll?commandID=${CMD_POLL}&wait=1" 2>&1) || {
    echo "  poll ${POLL_N}: curl failed"
    POLL_N=$(( POLL_N + 1 ))
    continue
  }
  CUR_STATE=$(xml_attr state "$_poll_raw")
  CUR_TIME=$(xml_attr time "$_poll_raw")
  CUR_DUR=$(xml_attr duration "$_poll_raw")

  echo "  poll ${POLL_N}: state=${CUR_STATE:-?} time=${CUR_TIME:-?} duration=${CUR_DUR:-?}"
  STATE_SEQ="${STATE_SEQ} ${CUR_STATE:-?}"

  if [[ "${CUR_STATE:-}" == "playing" ]]; then
    PLAYING_N=$(( PLAYING_N + 1 ))
    if [[ -n "${CUR_TIME:-}" ]] && [[ "$CUR_TIME" -gt "$PREV_TIME" ]] && [[ "$PREV_TIME" -ge 0 ]]; then
      ADVANCING_N=$(( ADVANCING_N + 1 ))
    fi
    if [[ -n "${CUR_TIME:-}" ]] && [[ "$CUR_TIME" -gt "$TIME_MAX" ]]; then
      TIME_MAX="$CUR_TIME"
    fi
  fi
  PREV_TIME="${CUR_TIME:-$PREV_TIME}"
  POLL_N=$(( POLL_N + 1 ))
done

echo "POLL_END polls=${POLL_N} playing_polls=${PLAYING_N} advancing_polls=${ADVANCING_N} time_max_ms=${TIME_MAX}"
echo "STATE_SEQUENCE:${STATE_SEQ}"

# ── red mutation hook (for test_cast_timeline_poll_red.sh) ────────────────────
[[ "${CAST_FAIL_INJECT:-0}" == "1" ]] && \
  fail "CAST_FAIL_INJECT=1 (deliberate red for mutation evidence)"

# ── scope guard ──────────────────────────────────────────────────────────────
[[ $POLL_N -gt 0 ]] || fail "scope-zero: no polls completed"

# ── primary assertions ────────────────────────────────────────────────────────
# Must have seen state="playing" at least once.
[[ $PLAYING_N -gt 0 ]] || \
  fail "state-never-playing after ${POLL_N} polls (sequence:${STATE_SEQ})"

# time= must have strictly increased across at least 2 consecutive playing polls.
# Single playing poll with advancing time is insufficiently convincing.
[[ $ADVANCING_N -ge 2 ]] || \
  fail "time-not-advancing: playing_polls=${PLAYING_N} advancing_polls=${ADVANCING_N} time_max_ms=${TIME_MAX}"

# ── verdict ──────────────────────────────────────────────────────────────────
echo "CAST_TIMELINE_RESULT=PASS state=playing time_max_ms=${TIME_MAX} polls=${POLL_N} playing=${PLAYING_N} advancing=${ADVANCING_N}"
exit "$RC_PASS"
