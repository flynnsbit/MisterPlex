#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$root"
mkdir -p build/session
work="$root/build/session/compressed-runtime-$$"
mkdir "$work"
trap 'if [[ "${MPX_KEEP_TEST_WORK:-0}" == 1 ]]; then printf "Retained work: %s\n" "$work"; else rm -rf -- "$work"; fi' EXIT
export TMPDIR="$work"
export PYTHONDONTWRITEBYTECODE=1

make -s -j1 "$root/build/test_resolve" "$root/build/test_avclock"
build/test_resolve
build/test_avclock
run_hls() {
    local sanitize=()
    if [[ "${MPX_HLS_SANITIZE:-0}" == 1 ]]; then
        sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    fi
    ${CXX:-g++} -std=c++17 -O1 -Wall -DMPX_HAVE_LIBAV -DMPX_FPGA_AV_TRACE=1 \
        "${sanitize[@]}" \
        -Ihost $(pkg-config --cflags libavformat libavcodec libavutil libswresample) \
        tests/unit/test_finite_hls.cpp arm/misterplexd/av_inproc_decode.cpp \
        $(pkg-config --libs libavformat libavcodec libavutil libswresample) \
        -pthread -ldl -o "$work/finite-hls"
    python3 tests/unit/test_finite_hls.py "$work/finite-hls" "$work"
}
if [[ "${MPX_COMPRESSED_TEST_SCOPE:-all}" == hls ]]; then
    run_hls
    exit
fi
${CXX:-g++} -std=c++17 -O2 -Wall -Ihost \
    tests/unit/test_fpga_terminal_accounting.cpp -o "$work/terminal"
"$work/terminal"

${CXX:-g++} -std=c++17 -O1 -DMPX_HAVE_LIBAV -Ihost \
    $(pkg-config --cflags libavformat libavcodec libavutil libswresample) \
    tests/unit/test_sps_parse.cpp arm/misterplexd/av_inproc_decode.cpp \
    $(pkg-config --libs libavformat libavcodec libavutil libswresample) \
    -pthread -o "$work/compressed"

x264='cabac=0:bframes=0:ref=1:weightp=0:partitions=none:qp=24:scenecut=0:slices=1:threads=1'
encode=(-v error -nostdin -f lavfi -i testsrc2=size=320x240:rate=24 -frames:v 12
    -c:v libx264 -profile:v baseline -level:v 3.0
    -colorspace smpte170m -color_primaries smpte170m -color_trc smpte170m -color_range tv)
ffmpeg "${encode[@]}" -x264-params "$x264:keyint=24" "$work/ip.mp4"
ffmpeg "${encode[@]}" -x264-params "$x264:keyint=1:no-deblock=1" "$work/idr-off.mp4"

"$work/compressed" --compressed "$work/ip.mp4" 12 limited-601
"$work/compressed" --compressed "$work/ip.mp4" 12 limited-601 all-idr reject-idr
"$work/compressed" --compressed "$work/ip.mp4" 12 limited-601 filter-off reject-filter
"$work/compressed" --compressed "$work/idr-off.mp4" 12 limited-601 all-idr filter-off

ffmpeg -v error -nostdin -i "$work/ip.mp4" -c:v copy \
    -bsf:v h264_mp4toannexb -f h264 "$work/ip.264"
# Negative fixture: retain the genuine intra-coded payload, but form a legal
# non-reference, non-IDR I picture. SPS/profile/color flags remain untouched.
python - "$work/ip.264" "$work/nonidr-i.264" <<'PY'
import pathlib
import re
import sys

raw = pathlib.Path(sys.argv[1]).read_bytes()
starts = list(re.finditer(b"\x00\x00(?:\x00)?\x01", raw))
nals = [raw[m.end():starts[i + 1].start() if i + 1 < len(starts) else len(raw)]
        for i, m in enumerate(starts)]

class Bits:
    def __init__(self, data):
        self.bits = "".join(f"{byte:08b}" for byte in data)
        self.pos = 0
    def u(self, size):
        value = int(self.bits[self.pos:self.pos + size], 2) if size else 0
        self.pos += size
        return value
    def ue(self):
        size = 0
        while self.u(1) == 0:
            size += 1
        return (1 << size) - 1 + self.u(size)

def rbsp(nal):
    return nal[1:].replace(b"\x00\x00\x03", b"\x00\x00")

sps = Bits(rbsp(next(n for n in nals if n[0] & 31 == 7)))
assert sps.u(8) == 66
sps.u(8)
assert sps.u(8) == 30
sps.ue()
frame_bits = sps.ue() + 4
assert sps.ue() == 2
idr = Bits(rbsp(next(n for n in nals if n[0] & 31 == 5)))
assert idr.ue() == 0
assert idr.ue() % 5 == 2
idr.ue()
frame_start = idr.pos
assert idr.u(frame_bits) == 0
idr.ue()
assert idr.u(1) == 0 and idr.u(1) == 0
bits = idr.bits[:frame_start] + format(1, f"0{frame_bits}b") + idr.bits[idr.pos:]
bits += "0" * (-len(bits) % 8)
payload = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
nal = bytearray([1])
zeros = 0
for byte in payload:
    if zeros >= 2 and byte <= 3:
        nal.append(3)
        zeros = 0
    nal.append(byte)
    zeros = zeros + 1 if byte == 0 else 0
prefix = []
for original in nals:
    prefix.append(original)
    if original[0] & 31 == 5:
        break
pathlib.Path(sys.argv[2]).write_bytes(
    b"".join(b"\x00\x00\x00\x01" + n for n in prefix + [bytes(nal)]))
PY

ffmpeg -v error -nostdin -r 24 -f h264 -i "$work/nonidr-i.264" \
    -c:v copy "$work/nonidr-i.mp4"
# Host-only fixture validity check, not part of the product decoder path.
ffmpeg -v error -nostdin -i "$work/nonidr-i.mp4" -f null -
"$work/compressed" --compressed "$work/nonidr-i.mp4" 2 limited-601 all-idr reject-idr

${CXX:-g++} -std=c++17 -O2 -Wall -DMPX_HAVE_LIBAV -DMPX_FPGA_AV_TRACE=1 -Ihost \
    $(pkg-config --cflags libavformat libavcodec libavutil libswresample) \
    tests/unit/test_compressed_demux_progress.cpp arm/misterplexd/av_inproc_decode.cpp \
    $(pkg-config --libs libavformat libavcodec libavutil libswresample) \
    -pthread -o "$work/progress"
for fixture in interleaved short long-audio; do
    video_duration=3 audio_duration=3
    [[ "$fixture" != short ]] || { video_duration=0.5; audio_duration=0.5; }
    [[ "$fixture" != long-audio ]] || { video_duration=0.5; audio_duration=6; }
    ffmpeg -v error -nostdin \
        -f lavfi -i "testsrc2=size=320x240:rate=24:duration=$video_duration" \
        -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$audio_duration" \
        -c:v libx264 -profile:v baseline -level:v 3.0 \
        -x264-params "$x264:qp=28:keyint=1:no-deblock=1" \
        -colorspace smpte170m -color_primaries smpte170m -color_trc smpte170m -color_range tv \
        -c:a aac -ar 48000 -ac 2 -streamid 0:256 -streamid 1:257 \
        -f mpegts "$work/$fixture.ts"
done
${CXX:-g++} -std=c++17 -O1 -ffunction-sections -fdata-sections -DMPX_HAVE_LIBAV \
    -Iarm/misterplexd -Ihost \
    $(pkg-config --cflags libavformat libavcodec libavutil libswresample) \
    tests/unit/test_compressed_input_failure.cpp arm/misterplexd/media_player.cpp \
    arm/misterplexd/av_inproc_decode.cpp arm/misterplexd/fpga_spi.cpp \
    arm/misterplexd/fb_present.cpp -Wl,--gc-sections \
    -Wl,--wrap=open -Wl,--wrap=avformat_open_input \
    $(pkg-config --libs libavformat libavcodec libavutil libswresample) \
    -pthread -o "$work/input-failure"
ffmpeg -v error -nostdin -i "$work/interleaved.ts" -map 0:v:0 -map 0:a:0 \
    -c copy "$work/input-fault.mkv"
"$work/input-failure" --io-error "$work/interleaved.ts"
"$work/input-failure" --io-error "$work/input-fault.mkv"
"$work/input-failure" --io-cancel "$work/input-fault.mkv"
"$work/input-failure" --io-external-cancel "$work/input-fault.mkv"
"$work/input-failure" --io-buffered-cancel "$work/interleaved.ts"
"$work/input-failure" --audio-open "$work/interleaved.ts"
# Adversarial real MPEG-TS packet order: retain every per-PID byte/PTS/counter,
# place video before audio, and let the actual libav demux/parser decode it.
python3 - "$work" <<'PY'
from pathlib import Path
import sys
work = Path(sys.argv[1])
for name, output in (("interleaved", "video-first"), ("short", "short-video-first")):
    data = (work / (name + ".ts")).read_bytes()
    assert len(data) % 188 == 0
    groups = [[], [], []]
    for offset in range(0, len(data), 188):
        packet = data[offset:offset + 188]
        assert packet[0] == 0x47
        pid = ((packet[1] & 31) << 8) | packet[2]
        groups[1 if pid == 256 else 2 if pid == 257 else 0].append(packet)
    assert groups[1] and groups[2]
    (work / (output + ".ts")).write_bytes(b"".join(b"".join(group) for group in groups))
PY
"$work/progress" "$work/interleaved.ts" "$work/video-first.ts" \
    "$work/short-video-first.ts" "$work/long-audio.ts"
terminal_input=(-f lavfi -i testsrc2=size=320x240:rate=24000/1001:duration=16.016
    -f lavfi -i sine=frequency=880:sample_rate=48000:duration=16.016)
if [[ -n "${MPX_TERMINAL_REPLAY_SOURCE:-}" ]]; then
    terminal_input=(-i "$MPX_TERMINAL_REPLAY_SOURCE" -map 0:v:0 -map 0:a:0)
fi
ffmpeg -v error -nostdin "${terminal_input[@]}" -frames:v 384 \
    -vf scale=320:240 -c:v libx264 -profile:v baseline -level:v 3.0 \
    -x264-params "$x264:qp=28:keyint=1:no-deblock=1" \
    -colorspace smpte170m -color_primaries smpte170m -color_trc smpte170m -color_range tv \
    -c:a aac -ar 48000 -ac 2 -f mpegts "$work/terminal-full.ts"
python3 - "$work" <<'PY'
from pathlib import Path
import json, subprocess, sys
work = Path(sys.argv[1])
full = work / "terminal-full.ts"
packets = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
    "-show_entries", "packet=pos", "-of", "json", str(full)]))["packets"]
assert len(packets) == 384
end = int(packets[264]["pos"])
assert end % 188 == 0
# A byte-identical short input, not a claimed reconstruction of the live PMS stream.
(work / "terminal-short.ts").write_bytes(full.read_bytes()[:end])
PY
"$work/progress" --terminal-full "$work/terminal-full.ts"
"$work/progress" --terminal-short "$work/terminal-short.ts"
run_hls
printf '%s\n' 'FPGA compressed runtime regressions passed (not hardware acceptance)'
