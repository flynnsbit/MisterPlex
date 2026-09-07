#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="${1:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264}"
FIXTURE="$(realpath "$FIXTURE")"
VSYNC_CYCLES="${FPGA_VIDEO_TB_VSYNC_CYCLES:-128}"
PPS_NEGATIVE="${FPGA_VIDEO_TB_NEGATIVE:-${FPGA_VIDEO_TB_PPS_NEGATIVE:-truncated}}"
IDR_ONLY="${FPGA_VIDEO_TB_IDR_ONLY:-0}"
NATIVE_BEAM="${FPGA_VIDEO_TB_NATIVE_BEAM:-1}"
SCANDOUBLE="${FPGA_VIDEO_TB_SCANDOUBLE:-1}"
if [[ ! "$NATIVE_BEAM" =~ ^[01]$ || ! "$SCANDOUBLE" =~ ^[01]$ ]]; then
  echo "native-beam and scandouble selections must be 0 or 1" >&2
  exit 1
fi
BUILD="$ROOT/build/verilator/fpga_video_au_publish"
mkdir -p "$BUILD/compiler-scratch"
export TMPDIR="$BUILD/compiler-scratch"
exec 9>"$BUILD/build.lock"
flock 9
RUN="$BUILD/runs/$(date +%s%N)"
mkdir -p "$RUN"
ffprobe -v error -threads 2 -select_streams v:0 \
  -show_entries stream=width,height:packet=pos,size,flags -of json \
  "$FIXTURE" > "$BUILD/packets.json"
ffmpeg -hide_banner -loglevel info -i "$FIXTURE" -frames:v 2 -c:v copy \
  -bsf:v trace_headers -f null - > /dev/null 2> "$BUILD/headers.trace"
python3 - "$FIXTURE" "$BUILD" "$VSYNC_CYCLES" "$PPS_NEGATIVE" "$IDR_ONLY" "$NATIVE_BEAM" "$SCANDOUBLE" <<'PY'
import json, pathlib, re, sys
fixture, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
if not sys.argv[3].isascii() or not sys.argv[3].isdigit():
    raise SystemExit("VSync cycle interval must be an unsigned decimal integer")
vsync_cycles = int(sys.argv[3])
if not 0 < vsync_cycles <= 1000000:
    raise SystemExit("VSync cycle interval outside bounded simulation range")
if sys.argv[4] not in ("truncated", "sps-mismatch", "bad-tail"):
    raise SystemExit("unsupported decoder negative mode")
if sys.argv[5] not in ("0", "1"):
    raise SystemExit("IDR-only profile must be 0 or 1")
(out / "simulation.json").write_text(json.dumps({
    "vsync_sys_cycles": vsync_cycles, "pps_negative": sys.argv[4],
    "idr_only_profile": bool(int(sys.argv[5])),
    "encoded_au_limit": 65536, "rbsp_addr_width": 16, "rbsp_cursor_width": 20,
    "native_presenter": bool(int(sys.argv[6])), "scandouble": bool(int(sys.argv[7]))
}) + "\n")
probe = json.loads((out / "packets.json").read_text())
stream = probe["streams"][0]
if not (0 < stream["width"] <= 320 and 0 < stream["height"] <= 240):
    raise SystemExit("composed AU gate requires a picture within 320x240")
trace = (out / "headers.trace").read_text()
def field(name, default=None):
    values = {int(n) for n in re.findall(
        rf"\b{re.escape(name)}\s+\S+\s*=\s*(-?\d+)\s*$", trace, re.MULTILINE)}
    if not values and default is not None:
        return default
    if len(values) != 1:
        raise SystemExit(f"missing or changing SPS geometry field: {name}")
    return values.pop()
if field("frame_mbs_only_flag") != 1 or field("chroma_format_idc", 1) != 1:
    raise SystemExit("composed geometry gate requires progressive 4:2:0")
cw = 16 * (field("pic_width_in_mbs_minus1") + 1)
ch = 16 * (field("pic_height_in_map_units_minus1") + 1)
cropped = field("frame_cropping_flag")
crops = [2 * field(f"frame_crop_{edge}_offset", 0 if not cropped else None)
         for edge in ("left", "right", "top", "bottom")]
left, right, top, bottom = crops
if not (0 < cw <= 320 and 0 < ch <= 240 and
        (cw - left - right, ch - top - bottom) == (stream["width"], stream["height"])):
    raise SystemExit("coded macroblocks/crop do not match independently decoded dimensions")
(out / "geometry.txt").write_text(" ".join(map(str, (cw, ch, *crops))) + "\n")
packets = probe["packets"][:2]
if len(packets) != 2 or "K" not in packets[0]["flags"]:
    raise SystemExit("composed AU gate requires two packets beginning with a keyframe")
data = fixture.read_bytes()
end = 0
for index, packet in enumerate(packets):
    offset, size = int(packet["pos"]), int(packet["size"])
    if offset != end or not 0 < size <= 65536 or offset + size > len(data):
        raise SystemExit("packet continuity/actual 65536-byte AU bound rejected fixture")
    (out / f"au{index}.264").write_bytes(data[offset:offset + size])
    end = offset + size
(out / "keyframes.bin").write_bytes(bytes(int("K" in packet["flags"]) for packet in packets))
PY
ffmpeg -v error -threads 2 -i "$FIXTURE" -frames:v 2 -pix_fmt yuv420p \
  -f rawvideo -threads 2 -y "$BUILD/reference.yuv"
ffmpeg -v error -threads 2 -apply_cropping 0 -i "$FIXTURE" -frames:v 2 -pix_fmt yuv420p \
  -f rawvideo -threads 2 -y "$BUILD/reference-coded.yuv"
SOURCES=()
while read -r command option kind source; do
  if [[ "$command" == set_global_assignment && "$kind" == SYSTEMVERILOG_FILE &&
        "$source" == rtl/* ]]; then
    SOURCES+=("$ROOT/fpga/Plex_MiSTer/$source")
  fi
done < "$ROOT/fpga/Plex_MiSTer/files.qip"
sha256sum "$ROOT/tests/unit/test_fpga_video_au_publish.sh" \
  "$ROOT/scripts/run_verilator.sh" "$ROOT/fpga/Plex_MiSTer/files.qip" \
  "$ROOT/tests/rtl/fpga_video_publish_tb_top.sv" \
  "$ROOT/tests/rtl/fpga_video_publish_tb.cpp" "${SOURCES[@]}" \
  "$ROOT"/fpga/Plex_MiSTer/rtl/*.svh \
  "$ROOT/host/libmisterplex/ddr_bitstream_ring.hpp" \
  "$ROOT/host/libmisterplex/mailbox_abi_spec.hpp" \
  "$FIXTURE" "$BUILD/packets.json" "$BUILD/au0.264" "$BUILD/au1.264" \
  "$BUILD/keyframes.bin" "$BUILD/reference.yuv" "$BUILD/reference-coded.yuv" \
  "$BUILD/geometry.txt" "$BUILD/headers.trace" "$BUILD/simulation.json" > "$BUILD/inputs.sha256"
python3 - "$ROOT" "$BUILD/inputs.sha256" "$RUN" <<'PY'
import hashlib, io, pathlib, shutil, sys, tarfile
root, manifest, run = map(pathlib.Path, sys.argv[1:])
shutil.copy2(manifest, run / "inputs.sha256")
with tarfile.open(run / "inputs.tar", "w") as archive:
    for line in manifest.read_text().splitlines():
        digest, name = line.split(None, 1)
        path = pathlib.Path(name)
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != digest:
            raise SystemExit("source changed before immutable input capture")
        try:
            relative = path.relative_to(root)
        except ValueError:
            relative = pathlib.Path("external-fixture") / path.name
        entry = tarfile.TarInfo(str(relative))
        entry.size, entry.mode = len(content), 0o444
        archive.addfile(entry, io.BytesIO(content))
PY
"$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 2 \
  --Mdir "$BUILD" --top-module fpga_video_publish_tb -Wno-fatal \
  -GINTEGRATE_STREAM=1 -GIDR_ONLY_PROFILE="$IDR_ONLY" \
  -GNATIVE_BEAM="$NATIVE_BEAM" -GNATIVE_SCANDOUBLE="$SCANDOUBLE" \
  -DFULL_AU_RTL=1 -DDDR_FRAME_STORE=1 -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  -CFLAGS "-std=c++17 -O2 -DFULL_AU=1 -DFULL_AU_RUNTIME_GEOMETRY=1 -DFULL_AU_NATIVE_BEAM=$NATIVE_BEAM -DFULL_AU_SCANDOUBLE=$SCANDOUBLE -I$ROOT/host/libmisterplex" \
  "$ROOT/tests/rtl/fpga_video_publish_tb_top.sv" "${SOURCES[@]}" \
  "$ROOT/tests/rtl/fpga_video_publish_tb.cpp"
sha256sum "$BUILD/Vfpga_video_publish_tb" > "$RUN/binary.sha256"
set +e
"$BUILD/Vfpga_video_publish_tb" "$BUILD" "$RUN/actual.yuv" "$VSYNC_CYCLES" "$PPS_NEGATIVE" 2>&1 | tee "$RUN/execution.log"
RESULT=$?
set -e
if ! sha256sum --check --status "$BUILD/inputs.sha256"; then
  echo "FAIL composed AU source inputs changed during build or execution" >&2
  RESULT=2
fi
if [[ -f "$RUN/actual.yuv" ]]; then
  sha256sum "$RUN/actual.yuv" > "$RUN/actual.sha256"
fi
printf '%s\n' "$RESULT" > "$RUN/exit-code"
printf 'Composed AU bundle: %s\n' "$RUN"
exit "$RESULT"
