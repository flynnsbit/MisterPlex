#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
ADDR_W="${P2_RBSP_ADDR_W:-16}"
case "$ADDR_W" in 13|16) ;; *) echo "P2_RBSP_ADDR_W must be 13 (8 KiB) or 16 (64 KiB)" >&2; exit 2;; esac
export P2_RBSP_ADDR_W="$ADDR_W"
LEASE="${P2_NATIVE_PUBLISH_LEASE:-0}"
case "$LEASE" in 0|1) ;; *) echo "P2_NATIVE_PUBLISH_LEASE must be 0 or 1" >&2; exit 2;; esac
STATIC_IDR="${P2_STATIC_IDR_ONLY:-0}"
case "$STATIC_IDR" in 0|1) ;; *) echo "P2_STATIC_IDR_ONLY must be 0 or 1" >&2; exit 2;; esac
BUILD="$ROOT/build/p2-intra-controller-$ADDR_W"
if [[ "$LEASE" == "1" ]]; then BUILD="$BUILD-native-lease"; fi
if [[ "$STATIC_IDR" == "1" ]]; then BUILD="$BUILD-static-idr"; fi
if [[ -n "${P2_RTL_SOURCE_DIR:-}" ]]; then BUILD="$BUILD-snapshot"; fi
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
RTL="${P2_RTL_SOURCE_DIR:-$ROOT/fpga/Plex_MiSTer/rtl}"
scripts/run_verilator.sh --cc --exe --build -j 2 -Wno-fatal \
  -GRBSP_ADDR_W="$ADDR_W" \
  -GNATIVE_PUBLISH_LEASE="$LEASE" \
  -GSTATIC_IDR_ONLY="$STATIC_IDR" \
  --top-module p2_intra_controller_tb --Mdir "$BUILD/obj" -I"$RTL" \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/host" \
  "$ROOT/tests/rtl/p2_intra_controller_tb.sv" "$ROOT/tests/rtl/p2_intra_controller_tb.cpp" \
  "$RTL"/{h264_mb_ctrl,h264_recon,h264_iq_idct_4x4,h264_intra_pred,h264_i16_dc_hadamard,h264_bit_reader,h264_slice_rbsp_ram,h264_residual_seq,h264_cavlc_residual,h264_dpb,h264_inter_pred,h264_p_slice_modes,h264_deblock,slice_hdr_parser}.sv \
  >"$BUILD/build.log" 2>&1 || { tail -60 "$BUILD/build.log"; exit 1; }
run_fixture() {
  local fixture="$1" name="$2" expect="${3:-0}" rc=0 full matrix pixfmt
  read -r full matrix < <(ffprobe -v error -select_streams v:0 \
    -show_entries stream=color_range,color_space -of json "$fixture" | python3 -c \
    'import json,sys;s=json.load(sys.stdin)["streams"][0];print(int(s.get("color_range")=="pc"),{"bt709":1,"bt470bg":5,"smpte170m":6}.get(s.get("color_space"),2))')
  pixfmt=yuv420p
  if [[ "$full" == "1" ]]; then pixfmt=yuvj420p; fi
  ffmpeg -hide_banner -loglevel error -nostdin -threads 1 -apply_cropping 0 -i "$fixture" \
    -pix_fmt "$pixfmt" -f rawvideo -y "$BUILD/$name.ffmpeg.yuv"
  "$BUILD/obj/Vp2_intra_controller_tb" "$fixture" "$BUILD/$name.ffmpeg.yuv" "$BUILD/$name.actual.yuv" \
    "$full" "$matrix" >"$BUILD/$name.log" 2>&1 || rc=$?
  if [[ "$rc" != "$expect" ]]; then tail -60 "$BUILD/$name.log"; exit 1; fi
  tail -5 "$BUILD/$name.log"
}
if [[ $# -gt 0 ]]; then run_fixture "$1" run "${2:-0}"; exit 0; fi

if [[ "$STATIC_IDR" == "1" ]]; then
  run_fixture "$ROOT/tests/fixtures/p2_intra_controller/real_color_filter_off_320x240_1f.264" static-real-color
  run_fixture "$ROOT/tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264" static-filter-reject 3
  ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
    -i "nullsrc=s=320x212:r=24,geq=lum='32+X/4+Y/4+2*N':cb='64+X/2+Y/4':cr='192-X/2+Y/4'" \
    -frames:v 2 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 20 \
    -x264-params 'cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0:partitions=none' \
    -f h264 -y "$BUILD/static-cropped-idrs.264"
  run_fixture "$BUILD/static-cropped-idrs.264" static-cropped-idrs
  run_fixture "$ROOT/tests/fixtures/gop12_oracle_color_filter_off/textured_color_fractional_filter_off_320x240_12f.264" \
    static-non-idr-reject 5
  grep -q 'STATIC_NON_IDR_REJECT runtime_policy=0' "$BUILD/static-non-idr-reject.log"
  echo "PASS static IDR-only color/crop reconstruction and non-IDR/filter rejection"
  exit 0
fi

ORIGINAL="$ROOT/tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264"
run_fixture "$ORIGINAL" filter-on-reject 3
grep -q 'EXPLICIT_FILTER_REJECT' "$BUILD/filter-on-reject.log"
# Frozen ordinary re-encode, with provenance beside the fixture. Never patch
# filtering flags or change the independent decoder's filtering.
cp "$ROOT/tests/fixtures/p2_intra_controller/real_color_filter_off_320x240_1f.264" "$BUILD/real-color.264"
run_fixture "$BUILD/real-color.264" real-color
P2_HEADER_AT_END=1 run_fixture "$BUILD/real-color.264" real-color-late-header
if [[ "$LEASE" == "1" ]]; then
  for cancel in reset vcl; do
    P2_NATIVE_CANCEL="$cancel" run_fixture "$BUILD/real-color.264" "native-cancel-$cancel"
    grep -q "NATIVE_CANCEL mode=$cancel.*frames=0" "$BUILD/native-cancel-$cancel.log"
  done
fi
for qp in 20 1; do
  ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
    -i "nullsrc=s=320x240,geq=lum='32+X/4+Y/4':cb='64+X/2+Y/4':cr='192-X/2+Y/4'" \
    -frames:v 1 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp "$qp" \
    -x264-params 'cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0:partitions=none' \
    -f h264 -y "$BUILD/gradient-qp$qp.264"
  run_fixture "$BUILD/gradient-qp$qp.264" "gradient-qp$qp"
done
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
  -i "nullsrc=s=320x240:r=24,geq=lum='32+X/4+Y/4+if(eq(N,1)*lt(X,64)*lt(Y,64),60*mod(floor(X/4)+floor(Y/4),2)-30,0)':cb='64+X/2+Y/4+if(eq(N,1)*lt(X,32)*lt(Y,32),30,0)':cr='192-X/2+Y/4'" \
  -frames:v 2 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 20 \
  -x264-params 'cabac=0:no-deblock=1:keyint=12:min-keyint=12:scenecut=0:ref=1:bframes=0:8x8dct=0:partitions=none:weightp=0' \
  -f h264 -y "$BUILD/intra-in-p.264"
run_fixture "$BUILD/intra-in-p.264" intra-in-p
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
  -i "nullsrc=s=320x240:r=24,geq=lum='if(eq(N,1)*between(X,64,127)*between(Y,64,127),128,32+X/4+Y/4)':cb='if(eq(N,1)*between(X,32,63)*between(Y,32,63),128,64+X/2+Y/4)':cr='if(eq(N,1)*between(X,32,63)*between(Y,32,63),128,192-X/2+Y/4)'" \
  -frames:v 2 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 20 \
  -x264-params 'cabac=0:no-deblock=1:keyint=12:min-keyint=12:scenecut=0:ref=1:bframes=0:8x8dct=0:partitions=none:weightp=0:constrained-intra=1' \
  -f h264 -y "$BUILD/constrained-patch.264"
run_fixture "$BUILD/constrained-patch.264" constrained-patch
P2_IDR_ONLY=1 run_fixture "$BUILD/real-color.264" profile-zero-ref-idr
P2_IDR_ONLY=1 run_fixture "$BUILD/intra-in-p.264" profile-idr-only-reject 1
P2_SPS_MAX_REFS=0 run_fixture "$BUILD/intra-in-p.264" profile-zero-ref-p-reject 1
P2_SPS_MAX_REFS=2 run_fixture "$BUILD/real-color.264" profile-overref-reject 1
grep -q 'sps_max_refs=0' "$BUILD/profile-zero-ref-idr.log"
grep -q 'error=19.*writes=0 pixels=0 frames=1' "$BUILD/profile-idr-only-reject.log"
grep -q 'error=19.*writes=0 pixels=0 frames=1' "$BUILD/profile-zero-ref-p-reject.log"
grep -q 'error=19.*writes=0 pixels=0 frames=0' "$BUILD/profile-overref-reject.log"
for signal in tv:bt709 pc:smpte170m pc:bt709; do
  range="${signal%%:*}"
  space="${signal#*:}"
  pixfmt=yuv420p
  if [[ "$range" == "pc" ]]; then pixfmt=yuvj420p; fi
  ffmpeg -hide_banner -loglevel error -nostdin -threads 1 -i "$ORIGINAL" \
    -frames:v 1 -pix_fmt "$pixfmt" -color_range "$range" -colorspace "$space" \
    -c:v libx264 -threads 1 -profile:v baseline -qp 26 \
    -x264-params 'cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0' \
    -f h264 -y "$BUILD/color-$range-$space.264"
  run_fixture "$BUILD/color-$range-$space.264" "color-$range-$space"
done
MOTION_SOURCE="$ROOT/tests/fixtures/gop12_oracle_color/textured_color_fractional_320x240_12f.264"
run_fixture "$MOTION_SOURCE" color-motion-filter-reject 3
ffmpeg -hide_banner -loglevel error -nostdin -threads 1 -i "$MOTION_SOURCE" \
  -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 25 \
  -x264-params 'cabac=0:no-deblock=1:keyint=12:min-keyint=12:scenecut=0:ref=1:bframes=0:8x8dct=0:partitions=i4x4:weightp=0:ipratio=1' \
  -f h264 -y "$BUILD/color-motion-filter-off.264"
run_fixture "$BUILD/color-motion-filter-off.264" color-motion-filter-off
run_fixture "$ROOT/tests/fixtures/gop12_oracle_color_filter_off/textured_color_fractional_filter_off_320x240_12f.264" \
  color-motion-independent
P2_BAD_SAR=known-zero run_fixture "$BUILD/real-color.264" sar-known-zero-reject 1
P2_BAD_SAR=unknown-nonzero run_fixture \
  "$ROOT/tests/fixtures/gop12_oracle_color_filter_off/textured_color_fractional_filter_off_320x240_12f.264" \
  sar-unknown-nonzero-reject 1
grep -q 'error=17.*writes=0 pixels=0 frames=0' "$BUILD/sar-known-zero-reject.log"
grep -q 'error=17.*writes=0 pixels=0 frames=0' "$BUILD/sar-unknown-nonzero-reject.log"
# Match the recorded PMS geometry, not the recorded title or its original DAR.
ffmpeg -hide_banner -loglevel error -nostdin -threads 1 -i "$MOTION_SOURCE" \
  -frames:v 2 -vf scale=320:212,setsar=1 -pix_fmt yuv420p \
  -c:v libx264 -threads 1 -profile:v baseline -qp 25 \
  -x264-params 'cabac=0:no-deblock=1:keyint=12:min-keyint=12:scenecut=0:ref=1:bframes=0:8x8dct=0:partitions=i4x4:weightp=0:ipratio=1' \
  -f h264 -y "$BUILD/recorded-geometry-320x212.264"
run_fixture "$BUILD/recorded-geometry-320x212.264" recorded-geometry-320x212
# Coded geometry is bounded by the tier, not fixed to its maximum. Decode all
# coded samples independently; the controller emits only the SPS crop rectangle.
for geometry in 320x192 320x180 176x158 318x178 16x16; do
  ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
    -i "nullsrc=s=$geometry:r=24,geq=lum='32+X/4+Y/4+2*N':cb='64+X/2+Y/4':cr='192-X/2+Y/4'" \
    -frames:v 2 -vf setsar=12/11 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 20 \
    -x264-params 'cabac=0:no-deblock=1:keyint=12:min-keyint=12:scenecut=0:ref=1:bframes=0:8x8dct=0:partitions=none:weightp=0' \
    -f h264 -y "$BUILD/geometry-$geometry.264"
  run_fixture "$BUILD/geometry-$geometry.264" "geometry-$geometry"
done
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
  -i "nullsrc=s=176x160,geq=lum='32+X/4+Y/4':cb='64+X/2+Y/4':cr='192-X/2+Y/4'" \
  -frames:v 1 -vf setsar=12/11 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 20 \
  -x264-params 'cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0:partitions=none:crop-rect=2,4,6,8' \
  -f h264 -y "$BUILD/geometry-four-crops.264"
run_fixture "$BUILD/geometry-four-crops.264" geometry-four-crops
for offset in -12 12; do
  ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
    -i "nullsrc=s=176x160,geq=lum='32+X/4+Y/4':cb='64+X/2+Y/4':cr='192-X/2+Y/4'" \
    -frames:v 1 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 24 \
    -x264-params "cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0:partitions=none:psy=0:chroma-qp-offset=$offset" \
    -f h264 -y "$BUILD/chroma-bound-$offset.264"
  run_fixture "$BUILD/chroma-bound-$offset.264" "chroma-bound-$offset"
  grep -q "chroma_offset=$offset" "$BUILD/chroma-bound-$offset.log"
done
ffmpeg -hide_banner -loglevel error -nostdin -f lavfi \
  -i "nullsrc=s=352x192,geq=lum='32+X/4+Y/4':cb='64+X/2':cr='192-X/2'" \
  -frames:v 1 -pix_fmt yuv420p -c:v libx264 -threads 1 -profile:v baseline -qp 24 \
  -x264-params 'cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0:partitions=none' \
  -f h264 -y "$BUILD/geometry-overbound.264"
run_fixture "$BUILD/geometry-overbound.264" geometry-overbound 1
grep -q 'error=17.*writes=0 pixels=0 frames=0' "$BUILD/geometry-overbound.log"
# Reference files are ordinary independent decodes of each IDR-led segment,
# concatenated without a host scaler normalizing changing frame dimensions.
cat "$BUILD"/{real-color,geometry-320x192,geometry-176x158,geometry-16x16,geometry-four-crops}.264 \
  > "$BUILD/geometry-transitions.264"
cat "$BUILD"/{real-color,geometry-320x192,geometry-176x158,geometry-16x16,geometry-four-crops}.ffmpeg.yuv \
  > "$BUILD/geometry-transitions.ffmpeg.yuv"
"$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/geometry-transitions.264" \
  "$BUILD/geometry-transitions.ffmpeg.yuv" "$BUILD/geometry-transitions.actual.yuv" \
  > "$BUILD/geometry-transitions.log" 2>&1 || { tail -30 "$BUILD/geometry-transitions.log"; exit 1; }
for mode in P2_REJECT_GEOMETRY P2_ODD_CROP; do
  rc=0
  env "$mode=1" "$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/real-color.264" \
    "$BUILD/real-color.ffmpeg.yuv" "$BUILD/$mode.actual.yuv" > "$BUILD/$mode.log" 2>&1 || rc=$?
  [[ "$rc" == "1" ]]
  grep -q 'error=17.*writes=0 pixels=0 frames=0' "$BUILD/$mode.log"
done
for offset in -13 13; do
  rc=0
  P2_INVALID_CHROMA_OFFSET="$offset" "$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/real-color.264" \
    "$BUILD/real-color.ffmpeg.yuv" "$BUILD/chroma-offset-$offset.actual.yuv" \
    > "$BUILD/chroma-offset-$offset.log" 2>&1 || rc=$?
  [[ "$rc" == "1" ]]
  grep -q 'error=2.*writes=0 pixels=0 frames=0' "$BUILD/chroma-offset-$offset.log"
done
python3 - "$BUILD" <<'PY'
import hashlib, json, pathlib, random, sys
root = pathlib.Path(sys.argv[1])
fixture = pathlib.Path("tests/fixtures/p2_intra_controller/capacity_320x224_65536rbsp.264")
manifest = json.loads(fixture.with_suffix(".json").read_text())
assert hashlib.sha256(fixture.read_bytes()).hexdigest() == manifest["sha256"]
rng = random.Random(17494)
w, h = 320, 224
uv = bytes(32+(x+y)//2 for y in range(h//2) for x in range(w//2))
uv += bytes(224-(x+y)//2 for y in range(h//2) for x in range(w//2))
raw = b"".join(bytes(92+rng.randrange(72) for _ in range(w*h))+uv for _ in range(2))
(root / "capacity-large-ip.yuv").write_bytes(raw)
PY
ffmpeg -hide_banner -loglevel error -nostdin -f rawvideo -pixel_format yuv420p -video_size 320x224 \
  -i "$BUILD/capacity-large-ip.yuv" -frames:v 2 -c:v libx264 -threads 1 -profile:v baseline -qp 26 \
  -x264-params 'cabac=0:no-deblock=1:keyint=12:min-keyint=12:scenecut=0:ref=1:bframes=0:8x8dct=0:partitions=i4x4:ipratio=1:psy=0:weightp=0:crop-rect=0,0,0,12' \
  -f h264 -y "$BUILD/capacity-large-ip.264"
capacity_result=0
if [[ "$ADDR_W" == "13" ]]; then capacity_result=1; fi
run_fixture "$BUILD/capacity-large-ip.264" capacity-large-ip "$capacity_result"
run_fixture "$ROOT/tests/fixtures/p2_intra_controller/capacity_320x224_65536rbsp.264" capacity-exact "$capacity_result"
if [[ "$ADDR_W" == "16" ]]; then
  P2_HEADER_AT_END=1 P2_FRAGMENT_CAPTURE=1 P2_END_WITH_LAST_BYTE=1 \
    run_fixture "$ROOT/tests/fixtures/p2_intra_controller/capacity_320x224_65536rbsp.264" capacity-exact-fragmented
else
  grep -q 'error=14.*writes=0 pixels=0 frames=0' "$BUILD/capacity-large-ip.log"
  grep -q 'error=14.*writes=0 pixels=0 frames=0' "$BUILD/capacity-exact.log"
fi
# Corrupt only negative inputs, never the accepted oracle or its filter.
python3 - "$BUILD" <<'PY'
import os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
clean = (root / "real-color.264").read_bytes()
data = bytearray(clean)
data[-1] ^= 1
(root / "bad-tail.264").write_bytes(data)
(root / "oversize.264").write_bytes(clean + b"\x55" * (1 << int(os.environ["P2_RBSP_ADDR_W"])))
vcl = next(m.end() for m in re.finditer(rb"\x00\x00(?:\x00)?\x01", clean)
           if (clean[m.end()] & 31) in (1, 5))
(root / "bad-header.264").write_bytes(clean[:vcl + 1] + b"\x00")
exact = pathlib.Path("tests/fixtures/p2_intra_controller/capacity_320x224_65536rbsp.264").read_bytes()
(root / "capacity-plus-one.264").write_bytes(exact + b"\x55")
(root / "capacity-truncated.264").write_bytes(exact[:-1])
bad_pad = bytearray(exact)
bad_pad[-1] ^= 1
(root / "capacity-bad-pad.264").write_bytes(bad_pad)
other = (root / "geometry-176x158.264").read_bytes()
starts = list(re.finditer(rb"\x00\x00(?:\x00)?\x01", other))
suffix = b"".join(other[m.start():starts[i+1].start() if i+1<len(starts) else len(other)]
                  for i, m in enumerate(starts) if (other[m.end()] & 31) in (7, 8, 1))
reference_ip = (root / "intra-in-p.264").read_bytes()
ref_starts = list(re.finditer(rb"\x00\x00(?:\x00)?\x01", reference_ip))
first_p = next(m.start() for m in ref_starts if reference_ip[m.end()] & 31 == 1)
(root / "bad-geometry-transition.264").write_bytes(reference_ip[:first_p] + suffix)
(root / "bad-geometry-transition.ffmpeg.yuv").write_bytes(
    (root / "intra-in-p.ffmpeg.yuv").read_bytes()[:115200] +
    (root / "geometry-176x158.ffmpeg.yuv").read_bytes()[176*160*3//2:])
p_suffix = b"".join(reference_ip[m.start():ref_starts[i+1].start() if i+1<len(ref_starts) else len(reference_ip)]
                    for i, m in enumerate(ref_starts) if reference_ip[m.end()] & 31 in (7, 8, 1))
(root / "zero-to-one-without-idr.264").write_bytes(clean + p_suffix)
(root / "zero-to-one-without-idr.ffmpeg.yuv").write_bytes(
    (root / "real-color.ffmpeg.yuv").read_bytes() +
    (root / "intra-in-p.ffmpeg.yuv").read_bytes()[115200:])
# Make a legal non-reference P NAL: removing nal_ref_idc also removes its
# adaptive_ref_pic_marking_mode_flag. Coefficients and filter syntax are unchanged.
def unescape(data):
    out = bytearray()
    zeros = 0
    for byte in data:
        if zeros == 2 and byte == 3:
            zeros = 0
            continue
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)
def escape(data):
    out = bytearray()
    zeros = 0
    for byte in data:
        if zeros == 2 and byte <= 3:
            out.append(3)
            zeros = 0
        out.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(out)
class Bits:
    def __init__(self, data):
        self.data = "".join(f"{byte:08b}" for byte in data)
        self.pos = 0
    def u(self, width):
        if self.pos + width > len(self.data):
            raise ValueError("truncated fixture header")
        value = int(self.data[self.pos:self.pos+width] or "0", 2)
        self.pos += width
        return value
    def ue(self):
        zeros = 0
        while self.u(1) == 0:
            zeros += 1
        return (1 << zeros) - 1 + self.u(zeros)
nonref = bytearray()
converted = 0
for i, m in enumerate(starts):
    end = starts[i+1].start() if i+1 < len(starts) else len(other)
    header, payload = other[m.end()], other[m.end()+1:end]
    kind = header & 31
    bits = Bits(unescape(payload))
    if kind == 7:
        assert bits.u(8) == 66
        bits.u(16)
        bits.ue()
        frame_bits = bits.ue() + 4
        assert bits.ue() == 2
    elif kind == 1:
        assert bits.ue() == 0 and bits.ue() % 5 == 0 and bits.ue() == 0
        bits.u(frame_bits)
        if bits.u(1):
            assert bits.ue() == 0
        assert bits.u(1) == 0
        marking = bits.pos
        assert bits.u(1) == 0
        data = bits.data[:marking] + bits.data[marking+1:] + "0"
        payload = escape(bytes(int(data[j:j+8], 2) for j in range(0, len(data), 8)))
        header &= 0x9f
        converted += 1
    nonref.extend(other[m.start():m.end()] + bytes([header]) + payload)
assert converted == 1
(root / "nonref-p.264").write_bytes(nonref)
PY
run_fixture "$BUILD/nonref-p.264" nonref-p 1
grep -q 'error=18.*writes=0 pixels=0 frames=1' "$BUILD/nonref-p.log"
for negative in bad-tail oversize bad-header; do
  rc=0
  "$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/$negative.264" \
    "$BUILD/real-color.ffmpeg.yuv" "$BUILD/$negative.actual.yuv" \
    >"$BUILD/$negative.log" 2>&1 || rc=$?
  if [[ "$rc" != "1" ]]; then tail -20 "$BUILD/$negative.log"; exit 1; fi
  grep -q 'pixels=0 frames=0' "$BUILD/$negative.log"
done
rc=0
"$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/bad-geometry-transition.264" \
  "$BUILD/bad-geometry-transition.ffmpeg.yuv" "$BUILD/bad-geometry-transition.actual.yuv" \
  > "$BUILD/bad-geometry-transition.log" 2>&1 || rc=$?
[[ "$rc" == "1" ]]
grep -q 'error=13.*writes=0 pixels=0 frames=1' "$BUILD/bad-geometry-transition.log"
rc=0
"$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/zero-to-one-without-idr.264" \
  "$BUILD/zero-to-one-without-idr.ffmpeg.yuv" "$BUILD/zero-to-one-without-idr.actual.yuv" \
  > "$BUILD/zero-to-one-without-idr.log" 2>&1 || rc=$?
[[ "$rc" == "1" ]]
grep -q 'error=19.*writes=0 pixels=0 frames=1' "$BUILD/zero-to-one-without-idr.log"
if [[ "$ADDR_W" == "16" ]]; then
  for negative in capacity-plus-one capacity-truncated capacity-bad-pad; do
    rc=0
    "$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/$negative.264" "$BUILD/capacity-exact.ffmpeg.yuv" \
      "$BUILD/$negative.actual.yuv" > "$BUILD/$negative.log" 2>&1 || rc=$?
    [[ "$rc" == "1" ]]
    grep -q 'pixels=0 frames=0' "$BUILD/$negative.log"
  done
  grep -q 'error=14.*writes=0 pixels=0 frames=0' "$BUILD/capacity-plus-one.log"
  grep -q 'error=15' "$BUILD/capacity-bad-pad.log"
fi
python3 - "$BUILD" <<'PY'
import os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def coverage(name):
    line = re.findall(r"COVERAGE (.*)", (root / (name + ".log")).read_text())[-1]
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
real, plane, strong = map(coverage, ("real-color", "gradient-qp20", "gradient-qp1"))
assert real["i4_modes"] and real["i16_modes"] and real["chroma_ac_blocks"]
assert plane["i16_modes"] & 8 and plane["chroma_modes"] & 8
assert strong["coeff_abs"] > 255 and strong["chroma_ac_blocks"]
assert coverage("intra-in-p")["intra_in_p"] > 0
assert coverage("constrained-patch")["intra_in_p"] > 0
assert "error=15" in (root / "bad-tail.log").read_text()
assert "error=14" in (root / "oversize.log").read_text()
assert "error=16" in (root / "bad-header.log").read_text()
assert "header_at_end=1" in (root / "real-color-late-header.log").read_text()
assert "mb=240 " in (root / "geometry-320x180.log").read_text()
assert "pixels=57600 " in (root / "geometry-320x180.log").read_text()
assert "crop=2,6,4,8 visible=168x148 sar=12:11" in (root / "geometry-four-crops.log").read_text()
assert (root / "geometry-transitions.log").read_text().count("YUV mismatches=0,0,0") == 8
cycles = []
for motion_name in ("color-motion-filter-off", "color-motion-independent"):
    motion = coverage(motion_name)
    assert motion["i4_modes"] == 511 and motion["i16_modes"] & 8
    assert motion["chroma_modes"] == 15 and motion["qpel_phases"] == 65535 and motion["mc_borders"] == 15
    motion_log = (root / (motion_name + ".log")).read_text()
    assert motion_log.count("YUV mismatches=0,0,0") == 12
    cycles.extend(map(int, re.findall(r"CONTROLLER cycles=(\d+)", motion_log)))
recorded_geometry = (root / "recorded-geometry-320x212.log").read_text()
assert recorded_geometry.count("YUV mismatches=0,0,0") == 2
assert "coded=320x224 crop=0,0,0,12 visible=320x212 sar=1:1" in recorded_geometry
assert "mb=280 " in recorded_geometry and "writes=107520 pixels=67840 " in recorded_geometry
assert coverage("recorded-geometry-320x212")["mc_borders"] & 8
if os.environ["P2_RBSP_ADDR_W"] == "16":
    large = (root / "capacity-large-ip.log").read_text()
    assert large.count("YUV mismatches=0,0,0") == 2
    assert all(int(size)>16384 for size in re.findall(r"RBSP capacity=65536 payload=(\d+)", large))
    for name in ("capacity-exact", "capacity-exact-fragmented"):
        text = (root / (name+".log")).read_text()
        assert "capacity=65536 payload=65536 stored=65536 bits=524288 cursor=524288 eof=1 overflow=0" in text
        assert "YUV mismatches=0,0,0" in text
    assert "payload=65537 stored=65536" in (root / "capacity-plus-one.log").read_text()
    assert "payload=65535 stored=65535" in (root / "capacity-truncated.log").read_text()
over_budget = sum(value > 833333 for value in cycles)
print("PASS correctness: encoded YUV/I4/I16/plane/intra-in-P/color/strong-coeff/crop/SAR/geometry/stall/reject")
print(f"COLOR_MOTION_20MHZ_24FPS {'UNQUALIFIED' if over_budget else 'WITHIN_SIMULATED_BUDGET'} "
      f"cycles_min={min(cycles)} mean={sum(cycles)//len(cycles)} max={max(cycles)} "
      f"frames_over_budget={over_budget}/{len(cycles)} "
      f"headroom={100*(833333-max(cycles))/833333:.1f}% "
      f"goal25={'MET' if max(cycles)<=625000 else 'NOT_MET'} (not fabric timing)")
PY
