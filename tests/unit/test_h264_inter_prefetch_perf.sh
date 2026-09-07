#!/usr/bin/env bash
# Existing controller/BRAM harness, unchanged stimuli and ordinary decoder.
# Pass the already-encoded 12-frame legal color-motion fixture; never reencode.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ $# -ge 1 && $# -le 2 ]] || { echo "usage: $0 fixture.264 [source-root]" >&2; exit 2; }
FIXTURE="$(realpath "$1")"
SOURCE="$(realpath "${2:-$ROOT}")"
BUILD="$ROOT/build/verilator/h264_inter_prefetch_perf/runs/$(date +%s%N)"
mkdir -p "$BUILD/compiler-scratch" "$BUILD/source/fpga/Plex_MiSTer/rtl" \
  "$BUILD/source/tests/rtl" "$BUILD/source/host/libmisterplex"
cp -a "$SOURCE/fpga/Plex_MiSTer/rtl/." "$BUILD/source/fpga/Plex_MiSTer/rtl/"
cp -a "$SOURCE/host/libmisterplex/." "$BUILD/source/host/libmisterplex/"
cp "$SOURCE/tests/rtl/p2_intra_controller_tb.sv" "$SOURCE/tests/rtl/p2_intra_controller_tb.cpp" \
  "$ROOT/tests/rtl/h264_inter_prefetch_monitor.sv" "$BUILD/source/tests/rtl/"
cp "$FIXTURE" "$BUILD/fixture.264"
cd "$ROOT"
export TMPDIR="$BUILD/compiler-scratch"
SRC="$BUILD/source"
RTL="$SRC/fpga/Plex_MiSTer/rtl"
scripts/run_verilator.sh --cc --exe --build -j 1 -Wno-fatal \
  --top-module p2_intra_controller_tb --Mdir "$BUILD/obj" -I"$RTL" \
  -CFLAGS "-std=c++17 -O2 -I$SRC/host" \
  "$SRC/tests/rtl/p2_intra_controller_tb.sv" "$SRC/tests/rtl/p2_intra_controller_tb.cpp" \
  "$SRC/tests/rtl/h264_inter_prefetch_monitor.sv" \
  "$RTL"/{h264_mb_ctrl,h264_recon,h264_iq_idct_4x4,h264_intra_pred,h264_i16_dc_hadamard,h264_bit_reader,h264_slice_rbsp_ram,h264_residual_seq,h264_cavlc_residual,h264_dpb,h264_inter_pred,h264_p_slice_modes,h264_deblock,slice_hdr_parser}.sv \
  >"$BUILD/build.log" 2>&1 || { tail -60 "$BUILD/build.log"; exit 1; }
read -r FULL MATRIX < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=color_range,color_space -of json "$BUILD/fixture.264" | python3 -c \
  'import json,sys;s=json.load(sys.stdin)["streams"][0];print(int(s.get("color_range")=="pc"),{"bt709":1,"bt470bg":5,"smpte170m":6}.get(s.get("color_space"),2))')
FORMAT=yuv420p
[[ "$FULL" == 0 ]] || FORMAT=yuvj420p
ffmpeg -v error -nostdin -threads 1 -apply_cropping 0 -i "$BUILD/fixture.264" \
  -pix_fmt "$FORMAT" -f rawvideo -y "$BUILD/ordinary.yuv"
"$BUILD/obj/Vp2_intra_controller_tb" "$BUILD/fixture.264" "$BUILD/ordinary.yuv" \
  "$BUILD/actual.yuv" "$FULL" "$MATRIX" >"$BUILD/run.log" 2>&1 || {
    tail -60 "$BUILD/run.log"; exit 1;
  }
python3 - "$BUILD" <<'PY'
import hashlib, json, pathlib, re, statistics, sys
b = pathlib.Path(sys.argv[1])
log = (b / "run.log").read_text()
rows = [dict(zip(("cycles", "decode_cycles", "mb", "writes", "pixels", "frame"), map(int, m)))
        for m in re.findall(r"CONTROLLER cycles=(\d+) decode_cycles=(\d+) mb=(\d+).*?writes=(\d+) pixels=(\d+) frames=(\d+)", log)]
traffic = [tuple(map(int, m)) for m in re.findall(r"PREFETCH_TRAFFIC requests=(\d+) responses=(\d+)", log)]
assert len(rows) == len(traffic) == 12, "not the complete 12-frame workload"
assert log.count("YUV mismatches=0,0,0") == 12
assert re.search(r"qpel_phases=65535 mc_borders=15", log), "missing actual color-motion phase/border coverage"
assert (b / "actual.yuv").read_bytes() == (b / "ordinary.yuv").read_bytes()
for row, (accepted, returned) in zip(rows, traffic):
    assert row["mb"] == 300 and row["writes"] == 115200 and row["pixels"] == 76800
    assert accepted == returned
    row.update(read_requests=accepted, read_responses=returned,
               presentation_cycles=row["cycles"] - row["decode_cycles"])
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
tree = hashlib.sha256()
for path in sorted(p for p in (b / "source").rglob("*") if p.is_file()):
    tree.update(str(path.relative_to(b / "source")).encode() + b"\0" + path.read_bytes())
report = dict(fixture_sha256=sha(b / "fixture.264"), source_tree_sha256=tree.hexdigest(),
              dpb_sha256=sha(b / "source/fpga/Plex_MiSTer/rtl/h264_dpb.sv"),
              binary_sha256=sha(b / "obj/Vp2_intra_controller_tb"), frames=rows,
              min_cycles=min(r["cycles"] for r in rows),
              mean_cycles=statistics.mean(r["cycles"] for r in rows),
              max_cycles=max(r["cycles"] for r in rows),
              over_budget=sum(r["cycles"] > 833333 for r in rows),
              accepted_reads=sum(r["read_requests"] for r in rows))
(b / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print({k: report[k] for k in ("min_cycles", "mean_cycles", "max_cycles", "over_budget", "accepted_reads")})
assert report["over_budget"] == 0, "20MHz/24fps cycle budget exceeded; no output-FPS substitution"
print("PASS exact color-motion simulation including accepted RGB tail; not fit/timing/glass qualification")
print("Results:", b / "result.json")
PY
