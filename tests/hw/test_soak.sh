#!/usr/bin/env bash
# Multi-title soak skeleton: play/stop several keys against live misterplexd.
# Does not replace short HW suite; use for longer cast-client stability.
#
# Env:
#   MISTER_HOST   default 192.168.1.183
#   MISTER_CONF   optional path to local conf (for PLEX_TOKEN / keys); else remote conf notes
#   SOAK_KEYS     space-separated playMedia key= values (URL-encoded or raw paths)
#   SOAK_HOLD_S   seconds to leave each title playing (default 8)
#   SOAK_ROUNDS   full passes over the key list (default 1)
set -euo pipefail

HOST="${MISTER_HOST:-192.168.1.183}"
BASE="http://${HOST}:3005"
HOLD_S="${SOAK_HOLD_S:-8}"
ROUNDS="${SOAK_ROUNDS:-1}"
CONF_LOCAL="${MISTER_CONF:-}"

CURL=(curl -fsS --connect-timeout 5 --max-time 30)

log() { printf '[soak] %s\n' "$*"; }
fail() { log "FAIL: $*"; exit 1; }

# Optional conf: PLEX_TOKEN=… (token is usually cast-supplied; kept for future PMS direct play)
TOKEN=""
if [[ -n "$CONF_LOCAL" && -f "$CONF_LOCAL" ]]; then
  TOKEN=$(grep -E '^PLEX_TOKEN=' "$CONF_LOCAL" 2>/dev/null | head -1 | cut -d= -f2- || true)
  log "loaded conf $CONF_LOCAL (token ${TOKEN:+set}${TOKEN:-unset})"
fi

# Default keys: local paths that exist on typical MiSTer deploy + metadata stubs.
# Override with SOAK_KEYS for library rating keys, e.g.:
#   SOAK_KEYS='/library/metadata/3 /library/metadata/9 /media/fat/mistercast/test.mp4'
DEFAULT_KEYS=(
  "/media/fat/mistercast/test.mp4"
  "/library/metadata/1"
  "/library/metadata/3"
)
if [[ -n "${SOAK_KEYS:-}" ]]; then
  # shellcheck disable=SC2206
  KEYS=($SOAK_KEYS)
else
  KEYS=("${DEFAULT_KEYS[@]}")
fi

log "resources on $HOST…"
"${CURL[@]}" "$BASE/resources" | grep -q MiSTerPlex || fail "no MiSTerPlex on $BASE/resources"

cmd=0
play_one() {
  local key="$1"
  cmd=$((cmd + 1))
  local enc
  enc=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$key")
  local extra=()
  if [[ -n "$TOKEN" ]]; then
    extra+=(--data-urlencode "token=${TOKEN}")
  fi
  # Full scrubber-style bind when key looks like library metadata
  local pq_args=()
  if [[ "$key" == /library/metadata/* ]]; then
    local rk="${key##*/}"
    pq_args+=(
      --data-urlencode "containerKey=/playQueues/soak${rk}?own=1"
      --data-urlencode "playQueueItemID=${rk}"
      --data-urlencode "playQueueVersion=1"
      --data-urlencode "ratingKey=${rk}"
    )
  fi
  log "play key=$key (cmd=$cmd)"
  local body
  body=$("${CURL[@]}" --get "$BASE/player/playback/playMedia" \
    --data-urlencode "key=${key}" \
    --data-urlencode "offset=0" \
    --data-urlencode "commandID=${cmd}" \
    "${pq_args[@]+"${pq_args[@]}"}" \
    "${extra[@]+"${extra[@]}"}") || fail "playMedia HTTP failed for $key"
  echo "$body" | grep -q Timeline || fail "playMedia no Timeline for $key"

  sleep 1
  cmd=$((cmd + 1))
  local poll
  poll=$("${CURL[@]}" "$BASE/player/timeline/poll?commandID=${cmd}") || fail "poll failed"
  echo "$poll" | grep -Eq 'state="(playing|buffering)"' || fail "not playing after play: $poll"
  if [[ "$key" == /library/metadata/* ]]; then
    echo "$poll" | grep -q "key=\"${key}\"" || log "WARN: poll missing key (ok for local-path resolve paths)"
  fi

  log "hold ${HOLD_S}s…"
  sleep "$HOLD_S"

  cmd=$((cmd + 1))
  log "stop"
  "${CURL[@]}" "$BASE/player/playback/stop?commandID=${cmd}" >/dev/null || fail "stop failed"
  sleep 0.5
  cmd=$((cmd + 1))
  poll=$("${CURL[@]}" "$BASE/player/timeline/poll?commandID=${cmd}")
  echo "$poll" | grep -q 'location="navigation"' || fail "after stop not navigation: $poll"
  echo "$poll" | grep -Eq 'state="(buffering|stopped)"' || fail "after stop bad state: $poll"
}

log "keys (${#KEYS[@]}): ${KEYS[*]}  rounds=$ROUNDS hold=${HOLD_S}s"
for ((r = 1; r <= ROUNDS; r++)); do
  log "=== round $r/$ROUNDS ==="
  for k in "${KEYS[@]}"; do
    play_one "$k"
  done
done

log "OK — ${#KEYS[@]} titles × ${ROUNDS} rounds on $HOST"
echo "test_soak: OK on $HOST"
