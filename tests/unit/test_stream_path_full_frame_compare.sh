#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; full-frame stream_path comparison was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    echo "A skipped RTL gate is NOT a pass. Set ALLOW_MISSING_VERILATOR=1 only if you accept that RTL was never verified." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

command -v ffmpeg >/dev/null || { echo "RTL SIM ERROR: ffmpeg reference decoder not found" >&2; exit 2; }
command -v ffprobe >/dev/null || { echo "RTL SIM ERROR: ffprobe not found" >&2; exit 2; }

QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
BITSTREAM="${FULL_FRAME_BITSTREAM:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264}"
SEQUENCE="${FULL_FRAME_SEQUENCE:-$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json}"
RATCHET="${FULL_FRAME_RATCHET:-$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_full_frame_ratchet_v1.json}"
BUILD="$ROOT/build/verilator/stream_path_full_frame"
BUILD_FAULT="$ROOT/build/verilator/stream_path_full_frame_fault"
REF_DIR="$ROOT/build/p3_full_frame"
REF_RGB="$REF_DIR/reference.rgb"
COMPARE_JSON="$REF_DIR/frame_planes_compare.json"
FAULT_JSON="$REF_DIR/frame_planes_compare_fault.json"
TOP="$ROOT/tests/rtl/stream_path_full_frame_tb_top.sv"
TB="$ROOT/tests/rtl/stream_path_full_frame_tb.cpp"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
PRODUCT_RTL=(
  stream_path.sv
  stream_ingest.sv
  ddr_bitstream_reader.sv
  bitstream_fifo.sv
  nalu_scanner.sv
  sps_parser.sv
  pps_parser.sv
  slice_hdr_parser.sv
  h264_iq_idct_4x4.sv
  h264_inter_pred.sv
  decode_stub.sv
)

for f in "$QIP" "$BITSTREAM" "$SEQUENCE" "$RATCHET" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done

if ! grep -q '"format": "misterplex.p3.nal_sequence.v1"' "$SEQUENCE"; then
  echo "RTL SIM ERROR: sequence manifest is not misterplex.p3.nal_sequence.v1: $SEQUENCE" >&2
  exit 2
fi

RTL_ARGS=()
for rtl in "${PRODUCT_RTL[@]}"; do
  if [[ ! -f "$RTL_DIR/$rtl" ]]; then
    echo "RTL SIM ERROR: missing product RTL: $RTL_DIR/$rtl" >&2
    exit 2
  fi
  if ! grep -q "rtl/$rtl" "$QIP"; then
    echo "RTL SIM ERROR: files.qip does not list product RTL under simulation: rtl/$rtl" >&2
    exit 2
  fi
  RTL_ARGS+=("$RTL_DIR/$rtl")
done

read -r WIDTH HEIGHT FRAMES < <(
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,nb_read_frames \
    -count_frames -of csv=p=0 "$BITSTREAM" | tr ',' ' '
)
if [[ -z "${WIDTH:-}" || -z "${HEIGHT:-}" || -z "${FRAMES:-}" || "$FRAMES" == "N/A" || "$FRAMES" -lt 2 ]]; then
  echo "RTL SIM ERROR: ffprobe did not report a multi-frame reference geometry/count" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_FAULT" "$REF_DIR"
ffmpeg -v error -y -i "$BITSTREAM" -an -f rawvideo -pix_fmt rgb24 "$REF_RGB"
SOURCE_SHA=$(sha256sum "$BITSTREAM" | awk '{print $1}')
if ! grep -q "$SOURCE_SHA" "$SEQUENCE"; then
  echo "RTL SIM ERROR: sequence manifest sha256 does not match bitstream" >&2
  exit 2
fi
if ! grep -q "$SOURCE_SHA" "$RATCHET"; then
  echo "RTL SIM ERROR: ratchet baseline sha256 does not match bitstream" >&2
  exit 2
fi
expected_size=$((WIDTH * HEIGHT * 3 * FRAMES))
actual_size=$(wc -c < "$REF_RGB")
if [[ "$actual_size" -ne "$expected_size" ]]; then
  echo "RTL SIM ERROR: reference RGB size $actual_size != expected $expected_size" >&2
  exit 2
fi

echo "RTL SIM: using $VERILATOR_VERSION (stream_path_full_frame_compare ${WIDTH}x${HEIGHT} frames=${FRAMES})" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -GFAULT_PIXEL_XOR=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

"$BUILD/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --ref-rgb "$REF_RGB" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$COMPARE_JSON" --expect-red
grep -q '"format": "misterplex.p3.frame_planes_compare.v1"' "$COMPARE_JSON"
grep -q '"sequence_manifest":' "$COMPARE_JSON"
python3 - "$COMPARE_JSON" "$RATCHET" <<'PY'
import json
import sys

actual = json.load(open(sys.argv[1]))
ratchet = json.load(open(sys.argv[2]))
if ratchet.get("format") != "misterplex.p3.frame_planes_ratchet.v1":
    raise SystemExit("FAIL full-frame ratchet: unknown ratchet format")
if actual["source"]["sha256"] != ratchet.get("source_sha256"):
    raise SystemExit("FAIL full-frame ratchet: source sha256 mismatch")
if actual["geometry"].get("colorspace") != ratchet.get("colorspace"):
    raise SystemExit("FAIL full-frame ratchet: colorspace mismatch")

planes = {}
for frame in actual["frames"]:
    for plane in frame["planes"]:
        planes[(frame["frame_index"], plane["plane"])] = plane

failures = []
eps = 1e-6
for metric in ratchet["metrics"]:
    key = (metric["frame_index"], metric["plane"])
    got = planes.get(key)
    if got is None:
        failures.append(f"missing frame={key[0]} plane={key[1]}")
        continue
    if got["exact_pixels"] < metric["min_exact_pixels"]:
        failures.append(f"frame={key[0]} plane={key[1]} exact {got['exact_pixels']} < {metric['min_exact_pixels']}")
    if got["mae"] > metric["max_mae"] + eps:
        failures.append(f"frame={key[0]} plane={key[1]} mae {got['mae']} > {metric['max_mae']}")
    if got["max_abs"] > metric["max_abs"]:
        failures.append(f"frame={key[0]} plane={key[1]} max_abs {got['max_abs']} > {metric['max_abs']}")

if failures:
    print("FAIL full-frame ratchet: divergence metrics regressed")
    for item in failures[:20]:
        print("  " + item)
    raise SystemExit(1)

print(f"OK full-frame ratchet: {len(ratchet['metrics'])} frame/plane metrics did not regress")
PY

set +e
FAULT_OUT="$("$BUILD_FAULT/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --ref-rgb "$REF_RGB" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$FAULT_JSON" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT" | grep -E 'FULL_FRAME_COMPARE summary|FAIL full-frame strict|FULL_FRAME_COMPARE raw frame=0 .*plane='
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL full-frame red-check: faulted pixel stream unexpectedly matched reference" >&2
  exit 1
fi
if ! grep -q 'FAIL full-frame strict:' <<<"$FAULT_OUT"; then
  echo "FAIL full-frame red-check: strict comparator did not report the fault" >&2
  exit 1
fi
echo "OK full-frame red-check: behavioral pixel XOR fault fails strict reference comparison"
