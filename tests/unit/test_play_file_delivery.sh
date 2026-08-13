#!/usr/bin/env bash
# Guard lab --play-file delivery: video-only sources must not be killed by an
# empty optional audio output, zero decoded frames must fail loudly, and source
# aspect probing must time out against a stalled endpoint.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/misterplexd"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -n "$FFMPEG" ] && [ -x "$FFMPEG" ] || fail "ffmpeg not found"
make -C "$ROOT" plexd >/dev/null

WORK="$ROOT/build/unit_play_file_delivery"
mkdir -p "$WORK"
CONF="$WORK/misterplex_none.conf"
AUDIO_DEV="$WORK/fake_mraudio"
VIDEO="$WORK/video_only.mp4"
EMPTY="$WORK/empty.mp4"
UNKNOWN="$WORK/unknown.bin"
GOOD_LOG="$WORK/good.log"
BAD_LOG="$WORK/bad.log"
UNKNOWN_LOG="$WORK/unknown.log"
STALL_LOG="$WORK/stall.log"
STALL_PORT_FILE="$WORK/stall.port"

: >"$AUDIO_DEV"
cat >"$CONF" <<EOF_CONF
PRESENT=none
STREAM=0
IDLE_SCREEN=off
AUDIO_DEVICE=$AUDIO_DEV
EOF_CONF

"$FFMPEG" -v error -y \
  -f lavfi -i testsrc2=size=160x120:rate=4 \
  -t 1 -an -c:v libx264 -profile:v baseline -pix_fmt yuv420p \
  -movflags +faststart "$VIDEO"

"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "$VIDEO" --play-seconds 1 >"$GOOD_LOG" 2>&1 || {
    cat "$GOOD_LOG" >&2
    fail "video-only play-file should deliver frames"
  }
grep -q "audio disabled for session: no audio stream detected" "$GOOD_LOG" || {
  cat "$GOOD_LOG" >&2
  fail "video-only source did not log audio-disable guard"
}
grep -q "LAB play-file done frames=" "$GOOD_LOG" || {
  cat "$GOOD_LOG" >&2
  fail "successful play-file did not report delivered frame count"
}
grep -q "source aspect=4:3 owner=host_present no_fpga_transport" "$GOOD_LOG" || {
  cat "$GOOD_LOG" >&2
  fail "non-FPGA play-file did not preserve source aspect on the host"
}
if grep -q "zero frames delivered" "$GOOD_LOG"; then
  cat "$GOOD_LOG" >&2
  fail "successful play-file reported zero frames"
fi

# Keep a valid faststart header and DAR, but remove every complete video frame.
# This reaches the delivery guard instead of being rejected earlier by the
# independent fail-closed source-aspect gate.
cp "$VIDEO" "$EMPTY"
truncate -s 1200 "$EMPTY"
set +e
"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "$EMPTY" --play-seconds 1 >"$BAD_LOG" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || {
  cat "$BAD_LOG" >&2
  fail "empty play-file returned success"
}
grep -q "zero frames delivered" "$BAD_LOG" || {
  cat "$BAD_LOG" >&2
  fail "empty play-file did not fail loudly as zero frames delivered"
}
grep -Eq "short_read=1|got=0/" "$BAD_LOG" || {
  cat "$BAD_LOG" >&2
  fail "zero-frame diagnostic did not include short-read details"
}

: >"$UNKNOWN"
set +e
"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "$UNKNOWN" --play-seconds 1 >"$UNKNOWN_LOG" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || {
  cat "$UNKNOWN_LOG" >&2
  fail "unknown-aspect play-file returned success"
}
grep -q "source display aspect unavailable" "$UNKNOWN_LOG" || {
  cat "$UNKNOWN_LOG" >&2
  fail "unknown-aspect play-file did not fail closed"
}

rm -f "$STALL_PORT_FILE"
python3 - "$STALL_PORT_FILE" <<'PY' &
import pathlib
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
server.settimeout(10)
pathlib.Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
client, _ = server.accept()
client.settimeout(10)
try:
    while client.recv(4096):
        pass
except socket.timeout:
    pass
PY
STALL_PID=$!
for _ in $(seq 1 50); do
  [ -s "$STALL_PORT_FILE" ] && break
  sleep 0.02
done
[ -s "$STALL_PORT_FILE" ] || fail "stalled aspect endpoint did not start"
STALL_PORT=$(cat "$STALL_PORT_FILE")
start=$SECONDS
set +e
"$BIN" --ffmpeg "$FFMPEG" --conf "$CONF" --decode 160x120 \
  --play-file "http://127.0.0.1:${STALL_PORT}/stall" --play-seconds 1 >"$STALL_LOG" 2>&1
rc=$?
set -e
elapsed=$((SECONDS - start))
wait "$STALL_PID" || fail "stalled aspect endpoint failed"
[ "$rc" -ne 0 ] || {
  cat "$STALL_LOG" >&2
  fail "stalled aspect probe returned success"
}
[ "$elapsed" -le 7 ] || {
  cat "$STALL_LOG" >&2
  fail "stalled aspect probe exceeded deadline (${elapsed}s)"
}
grep -q "source display aspect unavailable" "$STALL_LOG" || {
  cat "$STALL_LOG" >&2
  fail "stalled aspect probe did not fail closed"
}

echo "test_play_file_delivery: OK"
