#!/usr/bin/env bash
# parent_cast_local.sh — LOCAL PMS cast harness (repo path; not session files/).
#
# Preferred for parent API-driven soaks. Does NOT drive Plex Web UI.
# For DoD control-plane (picker/UI transport) use:
#   tests/hw/e2e/run_cast_picker.sh
#
# ALL hosts/tokens from env — never commit lab IPs or tokens
# (tests/unit/test_no_private_data.sh).
#
# Required:
#   MISTER_HOST          companion host (port default 3005)
#   PLEX_TOKEN           or PLEX_TOKEN_FILE
#   PLEX_MACHINE_ID      PMS machineIdentifier
# Optional:
#   MISTER_PORT          default 3005
#   PLEX_ADDRESS         PMS host only (no scheme) — or parse from PLEX_BASE
#   PLEX_PORT            default 32400
#   PLEX_BASE            e.g. http://YOUR-PLEX-SERVER:32400
#   PLEX_KEY             default /library/metadata/3
#   CAST_PLAYER_ID       default misterplex-dev
#   PLEX_CLIENT_ID       default parent-orchestrator
#
# Usage:
#   export MISTER_HOST=… PLEX_TOKEN=… PLEX_MACHINE_ID=… PLEX_BASE=http://YOUR-PLEX-SERVER:32400
#   ./scripts/parent_cast_local.sh play
#   ./scripts/parent_cast_local.sh stop
#   ./scripts/parent_cast_local.sh status   # timeline + resources + telemetry
#   KEY=/library/metadata/13 ./scripts/parent_cast_local.sh play
#
# Exit: 0 HTTP success path | 1 fail | 2 missing env (UNVERIFIED-style)

set -u

rc_miss() { echo "UNVERIFIED parent_cast_local: $*" >&2; exit 2; }
rc_fail() { echo "FAIL parent_cast_local: $*" >&2; exit 1; }

MISTER_HOST="${MISTER_HOST:-}"
MISTER_PORT="${MISTER_PORT:-3005}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
if [[ -z "$PLEX_TOKEN" && -n "${PLEX_TOKEN_FILE:-}" && -f "${PLEX_TOKEN_FILE}" ]]; then
  PLEX_TOKEN="$(tr -d '\r\n' <"$PLEX_TOKEN_FILE")"
fi
PLEX_MACHINE_ID="${PLEX_MACHINE_ID:-}"
PLEX_KEY="${PLEX_KEY:-${KEY:-/library/metadata/3}}"
CAST_PLAYER_ID="${CAST_PLAYER_ID:-misterplex-dev}"
PLEX_CLIENT_ID="${PLEX_CLIENT_ID:-parent-orchestrator}"

PLEX_ADDRESS="${PLEX_ADDRESS:-}"
PLEX_PORT="${PLEX_PORT:-32400}"
if [[ -z "$PLEX_ADDRESS" && -n "${PLEX_BASE:-}" ]]; then
  # http://host:port → host, port
  base="${PLEX_BASE#http://}"
  base="${base#https://}"
  base="${base%%/*}"
  if [[ "$base" == *:* ]]; then
    PLEX_ADDRESS="${base%%:*}"
    PLEX_PORT="${base##*:}"
  else
    PLEX_ADDRESS="$base"
  fi
fi

[[ -n "$MISTER_HOST" ]] || rc_miss "MISTER_HOST unset"
[[ -n "$PLEX_TOKEN" ]] || rc_miss "PLEX_TOKEN or PLEX_TOKEN_FILE unset"
[[ -n "$PLEX_MACHINE_ID" ]] || rc_miss "PLEX_MACHINE_ID unset"
[[ -n "$PLEX_ADDRESS" ]] || rc_miss "PLEX_ADDRESS or PLEX_BASE unset"

PLAYER="${MISTER_HOST}:${MISTER_PORT}"
CMD="${1:-play}"
CMD_ID="${COMMAND_ID:-$(date +%s)}"

hdr=(-H "X-Plex-Client-Identifier: ${PLEX_CLIENT_ID}" -H "X-Plex-Target-Client-Identifier: ${CAST_PLAYER_ID}")

case "$CMD" in
play)
  url="http://${PLAYER}/player/playback/playMedia?address=${PLEX_ADDRESS}&port=${PLEX_PORT}&protocol=http&key=${PLEX_KEY}&machineIdentifier=${PLEX_MACHINE_ID}&token=${PLEX_TOKEN}&offset=0&commandID=${CMD_ID}&type=video"
  code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "${hdr[@]}" "$url" || true)"
  echo "parent_cast_local play http=${code} player=${PLAYER} key=${PLEX_KEY}"
  [[ "$code" == "200" ]] || rc_fail "playMedia HTTP ${code}"
  ;;
stop)
  url="http://${PLAYER}/player/playback/stop?commandID=${CMD_ID}"
  code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "${hdr[@]}" "$url" || true)"
  echo "parent_cast_local stop http=${code}"
  [[ "$code" == "200" ]] || rc_fail "stop HTTP ${code}"
  ;;
status|idle-check)
  res="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${PLAYER}/resources" || true)"
  tl="$(curl -sS -m 5 "http://${PLAYER}/player/timeline/poll?commandID=${CMD_ID}&wait=0" || true)"
  tel="$(curl -sS -m 5 "http://${PLAYER}/player/telemetry" || true)"
  state="$(printf '%s' "$tl" | sed -n 's/.*state="\([^"]*\)".*/\1/p' | head -1)"
  time_ms="$(printf '%s' "$tl" | sed -n 's/.*time="\([^"]*\)".*/\1/p' | head -1)"
  playing="$(printf '%s' "$tel" | sed -n 's/.*playing=\([0-9]\).*/\1/p' | head -1)"
  echo "parent_cast_local status resources_http=${res} timeline_state=${state:-?} time=${time_ms:-?} telemetry_playing=${playing:-NA}"
  [[ "$res" == "200" ]] || rc_fail "resources HTTP ${res}"
  if [[ "$CMD" == "idle-check" ]]; then
    if [[ "${state:-}" == "playing" || "${state:-}" == "paused" ]]; then
      rc_fail "idle-check timeline still ${state}"
    fi
    if [[ "${playing:-}" == "1" ]]; then
      rc_fail "idle-check telemetry playing=1"
    fi
    echo "P4_IDLE_OK resources=200 timeline_not_playing telemetry_playing=${playing:-NA}"
  fi
  ;;
*)
  echo "usage: $0 play|stop|status|idle-check" >&2
  exit 2
  ;;
esac
exit 0
