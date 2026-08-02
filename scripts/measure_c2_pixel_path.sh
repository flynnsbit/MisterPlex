#!/usr/bin/env bash
# One-shot C2 measurement: cast one item, settle, then capture busybox top's
# second sample and new media frame-health lines for a fixed window.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
PLAYER="${PLAYER_HOST:-$HOST}:3005"
KEY=""
OFFSET_MS=0
SETTLE_SEC=30
DURATION_SEC=180
COMMAND_ID="c2measure"

usage() {
  cat <<'USAGE'
Usage: scripts/measure_c2_pixel_path.sh --key /library/metadata/N [options]

Options:
  --key KEY          Plex key to cast (required; use the same key before/after)
  --offset-ms MS     Cast offset in ms (default: 0)
  --settle-sec N     Wait before sampling top (default: 30)
  --duration-sec N   Frame-health collection duration after top (default: 180)
  --command-id ID    Plex commandID (default: c2measure)

Environment:
  MISTER_HOST, MISTER_USER, MISTER_PASS, PLAYER_HOST
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="${2:?}"; shift 2 ;;
    --offset-ms) OFFSET_MS="${2:?}"; shift 2 ;;
    --settle-sec) SETTLE_SEC="${2:?}"; shift 2 ;;
    --duration-sec) DURATION_SEC="${2:?}"; shift 2 ;;
    --command-id) COMMAND_ID="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$KEY" ]]; then
  echo "--key is required" >&2
  usage >&2
  exit 2
fi

urlencode() {
  python3 - "$1" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

ssh_mister() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$USER@$HOST" "$@"
}

redact() {
  sed -E 's/X-Plex-Token=[^& ]+/X-Plex-Token=REDACTED/g; s/X-Plex-Token: [^[:space:]]+/X-Plex-Token: REDACTED/g'
}

# TWO-ROOTS: resolve live log on device (never bare v1 default).
# Empty/missing → NO_DATA (preserve unscoreable; do not invent 0).
_c2_remote_count() {
  local pat="$1"
  local resolve_inc
  resolve_inc="$(cat "$ROOT/tools/avsync_live_log_resolve.inc.sh")"
  ssh_mister "bash -s" <<REMOTE
set +e
${resolve_inc}
avsync_resolve_live_log
LOG=\$pick
if [ -z "\$LOG" ] || [ ! -r "\$LOG" ]; then
  echo MEASURE_STATUS=NO_DATA
  echo MEASURE_REASON=log_absent_or_unresolved
  echo log_src=\${LOG:-empty}
  exit 4
fi
echo log_src=\$LOG
n=\$(grep -c '$pat' "\$LOG" 2>/dev/null)
rc=\$?
if [ "\$rc" -ge 2 ] || [ -z "\$n" ]; then
  echo MEASURE_STATUS=NO_DATA
  echo MEASURE_REASON=grep_error
  exit 4
fi
echo MEASURE_STATUS=MEASURED
echo MEASURE_COUNT=\$n
exit 0
REMOTE
}
set +e
_c2_frames_blob=$(_c2_remote_count 'media: frames=')
_c2_frames_rc=$?
_c2_end_blob=$(_c2_remote_count 'media: session end')
_c2_end_rc=$?
set -e
if [ "$_c2_frames_rc" -ne 0 ]; then
  echo "NO-DATA START_COUNT (log absent or unreadable) — not measured 0"
  printf '%s\n' "$_c2_frames_blob" | sed 's/^/  /'
  START_COUNT=""
else
  START_COUNT=$(printf '%s\n' "$_c2_frames_blob" | sed -n 's/^MEASURE_COUNT=//p' | head -1)
fi
if [ "$_c2_end_rc" -ne 0 ]; then
  echo "NO-DATA START_END_COUNT (log absent or unreadable) — not measured 0"
  START_END_COUNT=""
else
  START_END_COUNT=$(printf '%s\n' "$_c2_end_blob" | sed -n 's/^MEASURE_COUNT=//p' | head -1)
fi
echo "START_COUNT=${START_COUNT:-NO_DATA} START_END_COUNT=${START_END_COUNT:-NO_DATA}"

ENC_KEY="$(urlencode "$KEY")"
CAST_URL="http://${PLAYER}/player/playback/playMedia?key=${ENC_KEY}&offset=${OFFSET_MS}&commandID=${COMMAND_ID}"

echo "=== C2 measure cast ==="
echo "host=$HOST player=$PLAYER key=$KEY offset_ms=$OFFSET_MS settle_sec=$SETTLE_SEC duration_sec=$DURATION_SEC"
cast_body="$(curl -fsS "$CAST_URL")"
printf '%s' "$cast_body" | head -c 300 | redact
echo

echo "=== settling ${SETTLE_SEC}s ==="
sleep "$SETTLE_SEC"

echo "=== spawn line ==="
ssh_mister "grep 'spawn single-process' '$LOG' | tail -n 1" | redact || true

echo "=== top second sample ==="
ssh_mister "top -b -n2 -d2 | awk 'BEGIN{s=0} /^CPU:/{s++; if(s==2) print; next} s==2 && /misterplexd|ffmpeg/{print}'" | redact

echo "=== collecting frame health for ${DURATION_SEC}s ==="
sleep "$DURATION_SEC"

echo "=== new media frame lines ==="
if [ -n "${START_COUNT:-}" ]; then
  ssh_mister "grep 'media: frames=' '$LOG' | tail -n +$((START_COUNT + 1))" | redact || true
else
  echo "NO-DATA new media frames (START_COUNT unknown — log was not measurable at t0)"
fi

echo "=== new session end lines ==="
if [ -n "${START_END_COUNT:-}" ]; then
  ssh_mister "grep 'media: session end' '$LOG' | tail -n +$((START_END_COUNT + 1))" | redact || true
else
  echo "NO-DATA new session ends (START_END_COUNT unknown)"
fi
