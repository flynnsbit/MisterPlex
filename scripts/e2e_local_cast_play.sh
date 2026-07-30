#!/usr/bin/env bash
# End-to-end cast play without the user's PMS.
#
# Architecture (self-contained; safe for other lanes to reuse):
#   stub_pms_cast.py  — fake PMS (metadata + universal decision + media bytes)
#   misterplexd       — companion + resolve + FFmpeg present (product conf)
#   curl              — stub controller (playMedia with target id)
#
# Usage:
#   ./scripts/e2e_local_cast_play.sh
#   MEDIA=path/to.mp4 PLAY_SECONDS=30 ./scripts/e2e_local_cast_play.sh
#
# Conf:
#   Host lab (default): PRESENT=none so demux/decode run without /dev/mem.
#     Product PRESENT=fpga makes player.play() refuse when FPGA SPI is absent —
#     that is correct product behaviour, not a decode bug.
#   Device / product: PRESENT=fpga DECODE=320x240 STREAM=0 OSD_CONTROL=1
#     (set PRESENT=fpga explicitly; needs Plex.rbf + SPI for presents=).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MEDIA="${MEDIA:-$ROOT/assets/avsync/sync_trekmatch_320x240_24_blip.mp4}"
PLAY_SECONDS="${PLAY_SECONDS:-32}"
ID="${MISTERPLEX_ID:-misterplex-dev}"
WORK="${WORK:-$ROOT/build/e2e-local-cast}"
# Default none on host so cast E2E can measure frames/vfps without FPGA.
PRESENT_MODE="${PRESENT:-none}"
mkdir -p "$WORK"

FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"
[[ -n "$FFMPEG" && -x "$FFMPEG" ]] || { echo "FAIL: ffmpeg missing" >&2; exit 1; }
[[ -f "$MEDIA" ]] || { echo "FAIL: media missing: $MEDIA" >&2; exit 1; }

make -C "$ROOT" plexd >/dev/null
BIN="$ROOT/build/misterplexd"

# Two distinct free ports (pick-then-close races if called twice separately).
read -r STUB_PORT PLAYER_PORT < <(python3 - <<'PY'
import socket
ports = []
for p in range(13250, 13500):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", p))
    except OSError:
        s.close()
        continue
    ports.append((p, s))
    if len(ports) == 2:
        break
if len(ports) != 2:
    raise SystemExit("no free ports")
print(ports[0][0], ports[1][0])
for _, s in ports:
    s.close()
PY
)
STUB_BASE="http://127.0.0.1:${STUB_PORT}"
echo "e2e ports stub=${STUB_PORT} player=${PLAYER_PORT}"

CONF="$WORK/misterplex.conf"
# Product conf. AUDIO_DEVICE points at a writable sink so host runs don't stall
# forever waiting on missing /dev/MrAudio (device uses real MrAudio).
AUDIO_DEV="$WORK/fake_mraudio"
: >"$AUDIO_DEV"
echo "e2e PRESENT=${PRESENT_MODE} (product=fpga needs device SPI)"
cat >"$CONF" <<EOF
PLEX_BASE=${STUB_BASE}
PLEX_TOKEN=stub-token
DECODE=320x240
PRESENT=${PRESENT_MODE}
STREAM=0
OSD_CONTROL=1
AUDIO_DEVICE=${AUDIO_DEV}
IDLE_SCREEN=logo
EOF

STUB_LOG="$WORK/stub_pms.log"
DAEMON_LOG="$WORK/misterplexd.log"
: >"$STUB_LOG"
: >"$DAEMON_LOG"

python3 "$ROOT/scripts/stub_pms_cast.py" \
  --media "$MEDIA" --host 127.0.0.1 --port "$STUB_PORT" \
  --duration-ms 30000 --frame-rate 24 \
  >"$STUB_LOG" 2>&1 &
STUB_PID=$!

cleanup() {
  kill "$DAEMON_PID" 2>/dev/null || true
  kill "$STUB_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Stub must be healthy before daemon starts (else resolve hits nothing → testsrc).
stub_ok=0
for _ in $(seq 1 50); do
  if ! kill -0 "$STUB_PID" 2>/dev/null; then
    echo "FAIL: stub_pms died" >&2
    cat "$STUB_LOG" >&2 || true
    exit 1
  fi
  if curl -fsS "${STUB_BASE}/identity" >/dev/null 2>&1 \
     && curl -fsS "${STUB_BASE}/library/metadata/1" | grep -q MediaContainer; then
    stub_ok=1
    break
  fi
  sleep 0.1
done
if [[ "$stub_ok" != 1 ]]; then
  echo "FAIL: stub_pms not serving metadata on ${STUB_BASE}" >&2
  cat "$STUB_LOG" >&2 || true
  exit 1
fi
echo "stub_pms OK ${STUB_BASE}"

"$BIN" \
  --name MiSTerPlexE2E --id "$ID" --port "$PLAYER_PORT" \
  --conf "$CONF" --ffmpeg "$FFMPEG" --pms "$STUB_BASE" \
  >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

ok=0
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${PLAYER_PORT}/resources" >/dev/null 2>&1; then
    ok=1
    break
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.1
done
if [[ "$ok" != 1 ]]; then
  echo "FAIL: daemon not up" >&2
  cat "$DAEMON_LOG" >&2 || true
  cat "$STUB_LOG" >&2 || true
  exit 1
fi

RES=$(curl -fsS "http://127.0.0.1:${PLAYER_PORT}/resources")
echo "$RES" | grep -q "machineIdentifier=\"${ID}\"" || {
  echo "FAIL: resources id mismatch: $RES" >&2
  exit 1
}

# Cast: subscribe then playMedia (product path). Target header must match --id.
curl -fsS -H "X-Plex-Target-Client-Identifier: ${ID}" \
  "http://127.0.0.1:${PLAYER_PORT}/player/timeline/subscribe?commandID=1" >/dev/null

PLAY_URL="http://127.0.0.1:${PLAYER_PORT}/player/playback/playMedia?\
key=%2Flibrary%2Fmetadata%2F1&\
offset=0&\
address=127.0.0.1&\
port=${STUB_PORT}&\
protocol=http&\
machineIdentifier=stub-pms-cast&\
token=stub-token&\
commandID=2"

set +e
PLAY_CODE=$(curl -sS -o "$WORK/play.body" -w "%{http_code}" \
  -H "X-Plex-Target-Client-Identifier: ${ID}" \
  "$PLAY_URL")
set -e
echo "playMedia http=$PLAY_CODE"
if [[ "$PLAY_CODE" != "200" ]]; then
  echo "FAIL: playMedia want 200 got $PLAY_CODE" >&2
  cat "$WORK/play.body" >&2 || true
  cat "$DAEMON_LOG" >&2 || true
  exit 1
fi

# Wait for playback telemetry
deadline=$((SECONDS + PLAY_SECONDS + 5))
saw_playing=0
while (( SECONDS < deadline )); do
  if grep -q 'media: frames=' "$DAEMON_LOG" 2>/dev/null; then
    saw_playing=1
  fi
  # Natural EOF / stopped after play
  if grep -qE 'LAB play-file done|media: frames=.*vfps=' "$DAEMON_LOG" 2>/dev/null; then
    if grep -qE 'state="stopped"|session end|EOF|play-file done|frames=[6-9][0-9]{2,}' "$DAEMON_LOG" 2>/dev/null; then
      :
    fi
  fi
  # Exit early once we have a late telemetry line with large frame count or stopped
  if grep -qE 'media: frames=(6[0-9]{2}|[7-9][0-9]{2}|[1-9][0-9]{3,})' "$DAEMON_LOG" 2>/dev/null; then
    # allow a couple more seconds of logs
    sleep 2
    break
  fi
  # Timeline stopped after having played
  TL=$(curl -fsS -H "X-Plex-Target-Client-Identifier: ${ID}" \
    "http://127.0.0.1:${PLAYER_PORT}/player/timeline/poll?commandID=9" 2>/dev/null || true)
  if [[ "$saw_playing" == 1 ]] && echo "$TL" | grep -q 'state="stopped"'; then
    break
  fi
  sleep 0.5
done

# Explicit stop so session cleans up
curl -fsS -H "X-Plex-Target-Client-Identifier: ${ID}" \
  "http://127.0.0.1:${PLAYER_PORT}/player/playback/stop?commandID=99" >/dev/null || true
sleep 0.5

echo "----- daemon log (tail) -----"
tail -n 80 "$DAEMON_LOG" || true
echo "----- extract -----"

# Prefer last media: frames= line
LAST=$(grep 'media: frames=' "$DAEMON_LOG" | tail -n 1 || true)
PRESENTS_LINE=$(grep 'presents=' "$DAEMON_LOG" | tail -n 1 || true)
echo "last_telemetry=${LAST:-NONE}"
echo "last_presents=${PRESENTS_LINE:-NONE}"

python3 - <<'PY' "$DAEMON_LOG" "$WORK/metrics.env"
import re, sys
from pathlib import Path
log = Path(sys.argv[1]).read_text(errors="replace")
out = Path(sys.argv[2])
frames = vfps = pfps = presents = None
av_lock = 0
for m in re.finditer(
    r"media: frames=(\d+)\s+vfps=([0-9.]+)\s+pfps=([0-9.]+)",
    log,
):
    frames = int(m.group(1))
    vfps = float(m.group(2))
    pfps = float(m.group(3))
if "clock=av-lock" in log:
    av_lock = 1
for m in re.finditer(r"presents=(\d+)\s+frames=(\d+)", log):
    presents = int(m.group(1))
# Only real resolve success strings from plex_resolve.cpp detail=
resolved = "no"
detail = ""
for pat in (
    r"PMS universal[^\n]*",
    r"direct Part stream",
    r"direct H\.264 Part[^\n]*",
    r"direct URL",
    r"Part file path",
    r"PLAY [^\n]+",
):
    m = re.search(pat, log)
    if m:
        detail = m.group(0)
        if "testsrc" in detail or "test pattern" in detail:
            resolved = "testsrc_fallback"
        else:
            resolved = "yes"
        break
if "no such item on PMS" in log:
    resolved = "meta_miss"
lines = [
    f"FRAMES={frames if frames is not None else -1}",
    f"VFPS={vfps if vfps is not None else -1}",
    f"PFPS={pfps if pfps is not None else -1}",
    f"PRESENTS={presents if presents is not None else -1}",
    f"AV_LOCK={av_lock}",
    f"RESOLVED={resolved}",
]
out.write_text("\n".join(lines) + "\n")
print("\n".join(lines))
if detail:
    print("resolve_line=" + detail[:240])
PY

# shellcheck disable=SC1090
source "$WORK/metrics.env"

echo "e2e_metrics frames=$FRAMES vfps=$VFPS pfps=$PFPS presents=$PRESENTS av_lock=$AV_LOCK resolved=$RESOLVED"

if [[ "${RESOLVED:-no}" != "yes" ]]; then
  echo "FAIL: cast did not resolve real media (RESOLVED=$RESOLVED) — see daemon log" >&2
  exit 3
fi
# Hard fail if no frames at all — demux/decode broken
if [[ "${FRAMES:--1}" -lt 1 ]]; then
  echo "FAIL: no media: frames= telemetry (fetch/demux/decode broken?)" >&2
  exit 2
fi

echo "OK e2e local cast play (see metrics above; presents may be 0 on host without FPGA)"
