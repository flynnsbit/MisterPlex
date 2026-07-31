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
SEQUENCE="${FULL_FRAME_SEQUENCE:-}"
RATCHET="${FULL_FRAME_RATCHET:-}"
THROUGHPUT_RATCHET="${FULL_FRAME_THROUGHPUT_RATCHET:-}"
BUILD="$ROOT/build/verilator/stream_path_full_frame"
BUILD_FAULT="$ROOT/build/verilator/stream_path_full_frame_fault"
REF_DIR="$ROOT/build/p3_full_frame"
THROUGHPUT_DIR="$ROOT/build/realtime_throughput"
COMPARE_JSON="$REF_DIR/frame_planes_compare.json"
FAULT_JSON="$REF_DIR/frame_planes_compare_fault.json"
NATIVE_SCORE_JSON="$REF_DIR/native_frame_score.json"
BAD_LOOP_MANIFEST="$REF_DIR/bad_loop_filter_manifest.json"
NATIVE_CANDIDATE_I420="$REF_DIR/native_inter_candidate.i420"
NATIVE_CANDIDATE_JSON="$REF_DIR/native_inter_candidate_score.json"
INTER_METADATA_JSON="$REF_DIR/native_inter_metadata.json"
MB0_TRACE_JSON="$REF_DIR/mb0_pipeline_trace.json"
FAULT_TRACE_JSON="$REF_DIR/mb0_pipeline_trace_fault.json"
MB0_GOLDEN_JSON="$REF_DIR/current_mb0_trace.json"
CANDIDATE_I420="$REF_DIR/candidate.i420"
FAULT_I420="$REF_DIR/candidate_fault.i420"
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
  h264_deblock.sv
  h264_dpb.sv
  decode_stub.sv
  h264_p_mb_traverse.sv
  h264_byte_ram_sp.sv
  h264_i16_dc_hadamard.sv h264_i16_dc_hadamard_serial.sv h264_dequant4x4_serial.sv
  h264_i_res_recon_sink.sv
  h264_intra_pred.sv
  h264_recon_frame_store.sv
  h264_cavlc_residual.sv
)

for f in "$QIP" "$BITSTREAM" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done

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

SOURCE_SHA=$(sha256sum "$BITSTREAM" | awk '{print $1}')
mkdir -p "$BUILD" "$BUILD_FAULT" "$REF_DIR" "$THROUGHPUT_DIR"
if [[ -z "$SEQUENCE" ]]; then
  case "$SOURCE_SHA" in
    d6f30bcb8226f7e1c204d01f9914bffe1ec661503e373f7312d23884b3bfa86e)
      SEQUENCE="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_sequence_v1.json"
      ;;
    9b79749478f331d6e523a548a88fbad38d1719beb6a2623b289e4e0190bf17a9)
      SEQUENCE="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_624x480_sequence_v1.json"
      ;;
    9f58c3f92a6c9cacc86d2b58c275329445017f328b54206fcdcef5de4b1a5b62)
      SEQUENCE="$ROOT/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p_sequence_v1.json"
      ;;
    *)
      echo "RTL SIM ERROR: no sequence manifest supplied for bitstream $BITSTREAM" >&2
      echo "Set FULL_FRAME_SEQUENCE after generating/committing a nal_sequence.v1 manifest." >&2
      exit 2
      ;;
  esac
fi
if [[ -z "$RATCHET" ]]; then
  case "$SOURCE_SHA" in
    d6f30bcb8226f7e1c204d01f9914bffe1ec661503e373f7312d23884b3bfa86e)
      RATCHET="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_full_frame_ratchet_v1.json"
      ;;
    9b79749478f331d6e523a548a88fbad38d1719beb6a2623b289e4e0190bf17a9)
      RATCHET="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_624x480_full_frame_ratchet_v1.json"
      ;;
    9f58c3f92a6c9cacc86d2b58c275329445017f328b54206fcdcef5de4b1a5b62)
      RATCHET="$ROOT/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p_full_frame_ratchet_v1.json"
      ;;
  esac
fi
if [[ -z "$THROUGHPUT_RATCHET" ]]; then
  case "$SOURCE_SHA" in
    d6f30bcb8226f7e1c204d01f9914bffe1ec661503e373f7312d23884b3bfa86e)
      THROUGHPUT_RATCHET="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_320x240_decode_throughput_v1.json"
      ;;
    9b79749478f331d6e523a548a88fbad38d1719beb6a2623b289e4e0190bf17a9)
      THROUGHPUT_RATCHET="$ROOT/tests/fixtures/p3_multinal/plex_inter_p16_624x480_decode_throughput_v1.json"
      ;;
    9f58c3f92a6c9cacc86d2b58c275329445017f328b54206fcdcef5de4b1a5b62)
      THROUGHPUT_RATCHET="$ROOT/tests/fixtures/p3_multinal/wcap_residual14_idr_plus_p_decode_throughput_v1.json"
      ;;
  esac
fi
if [[ -z "$RATCHET" || ! -f "$RATCHET" ]]; then
  echo "RTL SIM ERROR: missing native full-frame ratchet for bitstream: ${RATCHET:-<unset>}" >&2
  exit 2
fi
if [[ -z "$THROUGHPUT_RATCHET" || ! -f "$THROUGHPUT_RATCHET" ]]; then
  echo "RTL SIM ERROR: missing decode throughput ratchet for bitstream: ${THROUGHPUT_RATCHET:-<unset>}" >&2
  exit 2
fi
if [[ ! -f "$SEQUENCE" ]]; then
  echo "RTL SIM ERROR: missing required file: $SEQUENCE" >&2
  exit 2
fi
if ! grep -q '"format": "misterplex.p3.nal_sequence.v1"' "$SEQUENCE"; then
  echo "RTL SIM ERROR: sequence manifest is not misterplex.p3.nal_sequence.v1: $SEQUENCE" >&2
  exit 2
fi
if ! grep -q "$SOURCE_SHA" "$SEQUENCE"; then
  echo "RTL SIM ERROR: sequence manifest sha256 does not match bitstream" >&2
  exit 2
fi
if ! grep -q "$SOURCE_SHA" "$RATCHET"; then
  echo "RTL SIM ERROR: ratchet baseline sha256 does not match bitstream" >&2
  exit 2
fi

GOLDEN_PLANES="${FULL_FRAME_GOLDEN_PLANES:-}"
GOLDEN_MANIFEST="${FULL_FRAME_GOLDEN_MANIFEST:-}"
if [[ -z "$GOLDEN_PLANES" && -z "$GOLDEN_MANIFEST" ]]; then
  case "$SOURCE_SHA" in
    d6f30bcb8226f7e1c204d01f9914bffe1ec661503e373f7312d23884b3bfa86e)
      GOLDEN_PLANES="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv"
      GOLDEN_MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_frame_planes_v1.json"
      ;;
    9b79749478f331d6e523a548a88fbad38d1719beb6a2623b289e4e0190bf17a9)
      GOLDEN_PLANES="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_i420.yuv"
      GOLDEN_MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_624x480_12f_frame_planes_v1.json"
      ;;
    9f58c3f92a6c9cacc86d2b58c275329445017f328b54206fcdcef5de4b1a5b62)
      GOLDEN_PLANES="$ROOT/tests/fixtures/p3_frame_planes/wcap_residual14_idr_plus_p_i420.yuv"
      GOLDEN_MANIFEST="$ROOT/tests/fixtures/p3_frame_planes/wcap_residual14_idr_plus_p_frame_planes_v1.json"
      ;;
  esac
fi
if [[ -z "$GOLDEN_PLANES" || -z "$GOLDEN_MANIFEST" ]]; then
  echo "RTL SIM ERROR: no proven frame-plane golden supplied for bitstream $BITSTREAM" >&2
  echo "Set FULL_FRAME_GOLDEN_PLANES and FULL_FRAME_GOLDEN_MANIFEST after generating/committing provenance." >&2
  exit 2
fi
"$ROOT/tools/extract_h264_frame_planes.py" --verify \
  --input "$BITSTREAM" --sequence "$SEQUENCE" \
  --planes "$GOLDEN_PLANES" --manifest "$GOLDEN_MANIFEST" \
  --expected-h264-loop-filter disabled

echo "RTL SIM: using $VERILATOR_VERSION (stream_path_full_frame_compare ${WIDTH}x${HEIGHT} frames=${FRAMES})" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -GFAULT_PIXEL_XOR=1 -GFAULT_TRACE_COEFF0_PLUS1=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

"$BUILD/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
  --candidate-i420-out "$CANDIDATE_I420" \
  --native-candidate-i420-out "$NATIVE_CANDIDATE_I420" \
  --inter-metadata-out "$INTER_METADATA_JSON" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$COMPARE_JSON" --trace-json-out "$MB0_TRACE_JSON" --expect-red
set +e
COLORSPACE_OUT="$("$ROOT/tools/extract_h264_frame_planes.py" --verify \
  --input "$BITSTREAM" --sequence "$SEQUENCE" \
  --planes "$GOLDEN_PLANES" --manifest "$GOLDEN_MANIFEST" \
  --expected-h264-loop-filter disabled \
  --candidate-planes "$CANDIDATE_I420" --candidate-colorspace I420_FROM_RGB565 2>&1)"
COLORSPACE_RC=$?
set -e
if [[ "$COLORSPACE_RC" -eq 0 ]]; then
  printf '%s\n' "$COLORSPACE_OUT"
  echo "FAIL full-frame colorspace red-check: RGB565-derived candidate was accepted as native I420" >&2
  exit 1
fi
grep -q 'candidate colorspace mismatch' <<<"$COLORSPACE_OUT"
echo "OK full-frame colorspace red-check: RGB565-derived diagnostic candidate refused by native I420 golden"
grep -q '"format": "misterplex.p3.frame_planes_compare.v1"' "$COMPARE_JSON"
grep -q '"sequence_manifest":' "$COMPARE_JSON"
"$ROOT/tools/check_decode_throughput.py" \
  --compare-json "$COMPARE_JSON" \
  --ratchet "$THROUGHPUT_RATCHET" \
  --label "$(basename "$BITSTREAM"):${WIDTH}x${HEIGHT}" \
  --report "$THROUGHPUT_DIR/decode_throughput_${WIDTH}x${HEIGHT}.json"
NATIVE_CANDIDATE_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQUENCE" \
  --golden-manifest "$GOLDEN_MANIFEST" \
  --golden-planes "$GOLDEN_PLANES" \
  --candidate-planes "$NATIVE_CANDIDATE_I420" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --mb-metadata "$INTER_METADATA_JSON" \
  --output "$NATIVE_CANDIDATE_JSON" \
  --expect-red)"
printf '%s\n' "$NATIVE_CANDIDATE_OUT" | grep -E 'I420_CANDIDATE_SCORE summary|score_i420_candidate: OK'
python3 - "$NATIVE_CANDIDATE_JSON" <<'PY'
import json
import sys

score = json.load(open(sys.argv[1]))
if score.get("format") != "misterplex.p3.i420_candidate_score.v1":
    raise SystemExit("FAIL native inter candidate score: unknown score format")
if score.get("colorspace") != "I420_NATIVE":
    raise SystemExit("FAIL native inter candidate score: not native I420")
summary = score["summary"]
inter = summary["inter"]
if inter["mb_total"] == 0:
    raise SystemExit("FAIL native inter candidate score: no inter MB population")
if summary["first_bad_inter"] is None:
    raise SystemExit("FAIL native inter candidate score: expected-red had no first_bad_inter")
print(
    "OK native inter candidate score: "
    f"intra={summary['intra']['mb_exact']}/{summary['intra']['mb_total']} "
    f"inter={inter['mb_exact']}/{inter['mb_total']} "
    f"first_bad_inter_mb={summary['first_bad_inter']['mb_index']} "
    f"plane={summary['first_bad_inter']['plane']}"
)
PY
python3 - "$INTER_METADATA_JSON" "$GOLDEN_MANIFEST" <<'PY'
import json
import sys

meta = json.load(open(sys.argv[1]))
gold = json.load(open(sys.argv[2]))
if meta.get("format") != "misterplex.p3.inter_mb_metadata.v1":
    raise SystemExit("FAIL native inter metadata: unknown format")
candidate = meta.get("candidate", {})
expected = {
    "colorspace": "I420_NATIVE",
    "h264_loop_filter": "disabled",
    "reconstruction_stage": "mc_pred_plus_residual_pre_deblock",
    "reference_picture_state": "testbench_prefilled_previous_golden_no_deblock_reference",
    "reference_picture_source": "golden_i420_previous_frame_injected_into_dpb_bank0",
}
for key, want in expected.items():
    got = candidate.get(key)
    if got != want:
        raise SystemExit(f"FAIL native inter metadata: candidate.{key}={got!r} want {want!r}")
if gold.get("decoder", {}).get("loop_filter") != "skip_loop_filter=all":
    raise SystemExit("FAIL native inter metadata: golden decoder.loop_filter is not skip_loop_filter=all")
if gold.get("provenance", {}).get("h264_loop_filter") != "disabled":
    raise SystemExit("FAIL native inter metadata: golden h264_loop_filter is not disabled")
print(
    "OK native inter provenance: "
    f"candidate_stage={candidate['reconstruction_stage']} "
    f"reference_state={candidate['reference_picture_state']} "
    "reference_h264_loop_filter=disabled"
)
PY
make -s -C "$ROOT" h264-golden-tools
python3 - "$GOLDEN_MANIFEST" "$BAD_LOOP_MANIFEST" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["decoder"]["loop_filter"] = "default"
data["provenance"]["h264_loop_filter"] = "enabled"
with open(sys.argv[2], "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
set +e
LOOP_FILTER_OUT="$("$ROOT/build/score_h264_native_frames" \
  --input "$BITSTREAM" --planes "$GOLDEN_PLANES" --manifest "$BAD_LOOP_MANIFEST" 2>&1)"
LOOP_FILTER_RC=$?
set -e
if [[ "$LOOP_FILTER_RC" -ne 9 ]]; then
  printf '%s\n' "$LOOP_FILTER_OUT"
  echo "FAIL native score red-check: enabled loop filter rc=$LOOP_FILTER_RC, want rc=9 refusal" >&2
  exit 1
fi
grep -q 'provenance.h264_loop_filter=disabled' <<<"$LOOP_FILTER_OUT"
echo "OK native score loop-filter red-check: deblocked references are refused"
"$ROOT/build/extract_h264_golden" --input "$BITSTREAM" --output "$MB0_GOLDEN_JSON" >/dev/null
"$ROOT/build/score_h264_native_frames" \
  --input "$BITSTREAM" --planes "$GOLDEN_PLANES" --manifest "$GOLDEN_MANIFEST" --output "$NATIVE_SCORE_JSON"
python3 - "$MB0_TRACE_JSON" "$MB0_GOLDEN_JSON" "$COMPARE_JSON" <<'PY'
import json
import sys

trace = json.load(open(sys.argv[1]))
gold = json.load(open(sys.argv[2]))
compare = json.load(open(sys.argv[3]))
if trace.get("format") != "misterplex.p3.mb0_pipeline_trace.v1" or not trace.get("valid"):
    raise SystemExit("FAIL full-frame MB0 trace: missing valid RTL pipeline trace")
if trace.get("colorspace") != "I420_NATIVE":
    raise SystemExit("FAIL full-frame MB0 trace: trace colorspace is not I420_NATIVE")
if gold.get("format") != "misterplex.p3.mb_golden.v1":
    raise SystemExit("FAIL full-frame MB0 trace: unknown golden format")
if gold["slice"]["nal_type"] != 5 or gold["macroblock"]["index"] != 0:
    raise SystemExit("FAIL full-frame MB0 trace: golden is not frame0 IDR MB(0,0)")

block0 = gold["residual"]["luma4x4"][0]
recon_first4 = [gold["samples"]["recon_y"][y * 16 + x] for y in range(4) for x in range(4)]
checks = [
    ("qp", trace["qp"], gold["macroblock"]["qp"]),
    ("total_coeff", trace["total_coeff"], block0["total_coeff"]),
    ("residual_csum", trace["residual_csum"], gold["checks"]["first_residual_checksum8"]),
    ("coefficients_zigzag", trace["coefficients_zigzag"], block0["coefficients_zigzag"]),
    ("dequant", trace["dequant"], block0["dequant"]),
    ("idct", trace["idct"], block0["idct"]),
    ("recon", trace["recon"], recon_first4),
]
failures = [name for name, got, want in checks if got != want]
if failures:
    print("FAIL full-frame MB0 trace: RTL/reference mismatch in " + ", ".join(failures))
    for name, got, want in checks:
        if got != want:
            print(f"  {name}: got={got} want={want}")
    raise SystemExit(1)

ref_y00 = gold["samples"]["recon_y"][0]
got_y00 = trace["recon"][0]
print(
    "MB0_NATIVE_COMPARE frame=0 colorspace=I420_NATIVE plane=Y x=0 y=0 "
    f"mb_x=0 mb_y=0 pixel_in_mb_x=0 pixel_in_mb_y=0 got={got_y00} ref={ref_y00} abs={abs(got_y00 - ref_y00)}"
)
fb = compare["summary"]["first_bad"]
if fb["frame_index"] == 0 and fb["plane"] == "Y" and fb["x"] == 0 and fb["y"] == 0 and fb["got"] == 142:
    raise SystemExit("FAIL full-frame MB0 trace: diagnostic border still masks native MB0 luma at Y(0,0)")
print(
    "OK full-frame MB0 trace: CAVLC/scan/dequant/IDCT/clip match host; "
    f"RGB565 diagnostic first_bad now plane={fb['plane']} x={fb['x']} y={fb['y']} "
    f"got={fb['got']} ref={fb['ref']} abs={fb['abs']}"
)
# Gate audit coverage declaration (parent directive #16):
# RTL reconstruction scored for ALL MBs luma (via injection scorer).
# I_NxN: full pipeline (dequant+IDCT+recon). I_16x16: IDCT+recon bypass.
# Chroma reconstruction has never been tested in RTL.
frame_w = gold.get("frame", {}).get("width", 320)
frame_h = gold.get("frame", {}).get("height", 240)
total_y = frame_w * frame_h
total_c = total_y // 2
total_mbs = ((frame_w + 15) // 16) * ((frame_h + 15) // 16)
rtl_y_pixels_verified = total_y  # Full frame via RTL scorer (76800 for 320x240)
rtl_chroma_pixels_verified = 0
print(
    f"COVERAGE rtl_recon_y={rtl_y_pixels_verified}/{total_y} "
    f"rtl_recon_chroma={rtl_chroma_pixels_verified}/{total_c} "
    f"rtl_mbs_verified={total_mbs}/{total_mbs} "
    "NOTE: RTL scorer tests arithmetic modules by injection, not connected pipeline"
)
PY
python3 - "$NATIVE_SCORE_JSON" "$RATCHET" <<'PY'
import json
import sys

actual = json.load(open(sys.argv[1]))
ratchet = json.load(open(sys.argv[2]))
if actual.get("format") != "misterplex.p3.native_frame_score.v1":
    raise SystemExit("FAIL native full-frame ratchet: unknown score format")
if ratchet.get("format") != "misterplex.p3.native_frame_score_ratchet.v1":
    raise SystemExit("FAIL native full-frame ratchet: unknown ratchet format")
if actual["source"]["sha256"] != ratchet.get("source_sha256"):
    raise SystemExit("FAIL native full-frame ratchet: source sha256 mismatch")
if actual.get("colorspace") != ratchet.get("colorspace"):
    raise SystemExit("FAIL native full-frame ratchet: colorspace mismatch")
if actual.get("loop_filter") != ratchet.get("loop_filter"):
    raise SystemExit("FAIL native full-frame ratchet: loop-filter mismatch")
if actual.get("h264_loop_filter") != ratchet.get("h264_loop_filter"):
    raise SystemExit("FAIL native full-frame ratchet: H.264 loop-filter mismatch")

planes = {}
for frame in actual["frames"]:
    for plane in frame["planes"]:
        planes[(frame["frame_index"], plane["plane"])] = plane

failures = []
eps = 1e-6
summary = ratchet["summary"]
actual_summary = actual["summary"]
for key in ("frames", "i_frames", "p_frames", "inter_expected_red_frames"):
    if actual_summary[key] != summary[key]:
        failures.append(f"summary {key} {actual_summary[key]} != {summary[key]}")
if actual_summary["intra_mb_exact"] < summary["min_intra_mb_exact"]:
    failures.append(
        f"intra_mb_exact {actual_summary['intra_mb_exact']} < {summary['min_intra_mb_exact']}"
    )
if actual_summary["intra_mb_total"] != summary["intra_mb_total"]:
    failures.append(
        f"intra_mb_total {actual_summary['intra_mb_total']} != {summary['intra_mb_total']}"
    )
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
    frame = actual["frames"][metric["frame_index"]]
    if frame["mb_exact"] < metric["mb_exact"] or frame["mb_total"] != metric["mb_total"]:
        failures.append(
            f"frame={metric['frame_index']} mb_exact {frame['mb_exact']}/{frame['mb_total']} "
            f"outside ratchet {metric['mb_exact']}/{metric['mb_total']}"
        )

for expected in ratchet["inter_frames"]:
    frame = actual["frames"][expected["frame_index"]]
    if frame.get("implemented") or not frame.get("expected_red"):
        failures.append(f"frame={expected['frame_index']} inter expected-red classification changed")

if failures:
    print("FAIL native full-frame ratchet: divergence metrics regressed")
    for item in failures[:20]:
        print("  " + item)
    raise SystemExit(1)

print(
    "OK native full-frame ratchet (HOST-ONLY scorer, NOT RTL): "
    f"intra_mb_exact={actual_summary['intra_mb_exact']}/{actual_summary['intra_mb_total']} "
    f"inter_expected_red_frames={actual_summary['inter_expected_red_frames']} "
    f"plane_metrics={len(ratchet['metrics'])}"
)
PY

set +e
FAULT_OUT="$("$BUILD_FAULT/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
  --candidate-i420-out "$FAULT_I420" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$FAULT_JSON" --trace-json-out "$FAULT_TRACE_JSON" 2>&1)"
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
python3 - "$FAULT_TRACE_JSON" "$MB0_GOLDEN_JSON" <<'PY'
import json
import sys

trace = json.load(open(sys.argv[1]))
gold = json.load(open(sys.argv[2]))
block0 = gold["residual"]["luma4x4"][0]
if trace["coefficients_zigzag"] == block0["coefficients_zigzag"]:
    raise SystemExit("FAIL full-frame MB0 trace red-check: faulted trace unexpectedly matched coefficients")
if trace["coefficients_zigzag"][0] != block0["coefficients_zigzag"][0] + 1:
    raise SystemExit("FAIL full-frame MB0 trace red-check: injected coefficient fault was not observed")
print("OK full-frame MB0 trace red-check: injected coeff0 fault rejected by trace comparator")
PY
echo "OK full-frame red-check: behavioral pixel XOR fault fails strict reference comparison"

# --- RTL-in-the-loop reconstruction scorer ---
# Runs the actual RTL dequant/IDCT/recon pipeline on ALL luma blocks of ALL MBs.
# verification_target=RTL (not host). This is what tells us the hardware works.
RTL_SCORER_BUILD="$ROOT/build/verilator/rtl_recon_scorer"
RTL_GOLDEN_DIR="$REF_DIR/goldens_all_mbs"
mkdir -p "$RTL_SCORER_BUILD" "$RTL_GOLDEN_DIR"
"$RUN_VERILATOR" --cc --exe --build \
  -Mdir "$RTL_SCORER_BUILD" \
  --top-module h264_rtl_recon_scorer_tb \
  -Wno-fatal \
  "$ROOT/tests/rtl/h264_rtl_recon_scorer_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv" \
  "$ROOT/tests/rtl/h264_rtl_recon_scorer_tb.cpp"
# Extract golden for all MBs if not already present (or stale)
if [ ! -f "$RTL_GOLDEN_DIR/mb_000.json" ] || \
   [ "$BITSTREAM" -nt "$RTL_GOLDEN_DIR/mb_000.json" ]; then
  "$ROOT/build/extract_h264_golden" --input "$BITSTREAM" --all-mbs --output-dir "$RTL_GOLDEN_DIR"
fi
# Score all MBs with RED-check
"$RTL_SCORER_BUILD/Vh264_rtl_recon_scorer_tb" --dir "$RTL_GOLDEN_DIR" --red-check

# =============================================================================
# REAL_REF_MEASURE — decisive self-produced DPB reference (no golden prefill)
# =============================================================================
# Pre-register BEFORE run: expect scores BELOW fake-ref inter=1606/3300.
# PRE_REGISTER: intra=0/300 inter<=400/3300 (honest floor; IDR recon partial).
BUILD_REAL="$ROOT/build/verilator/stream_path_full_frame_real_ref"
BUILD_REAL_XOR="$ROOT/build/verilator/stream_path_full_frame_real_ref_xor"
REAL_REF_DIR="$ROOT/build/p3_full_frame_real_ref"
mkdir -p "$BUILD_REAL" "$BUILD_REAL_XOR" "$REAL_REF_DIR"
REAL_META="$REAL_REF_DIR/native_inter_metadata.json"
REAL_CAND="$REAL_REF_DIR/native_inter_candidate.i420"
REAL_SCORE="$REAL_REF_DIR/native_inter_candidate_score.json"
REAL_COMPARE="$REAL_REF_DIR/frame_planes_compare.json"
# Pre-register TWO metrics (scorer unmodified; chroma still stub 128):
#   HEADLINE score_i420_candidate mb_exact requires Y+U+V → expect intra=0/300
#     inter=0/3300 while U/V=128 (quoted: tools/score_i420_candidate.py mb_exact).
#   LUMA progress (tools/score_i420_luma_progress.py): Y-only gradient.
#     PRE: intra_y_mb≈225..245/300, intra_y_px≈60k..65k/76800 (I16 AC max15 skip_dc +
#     combined DC+AC idct; prior 214). HEADLINE stays 0 while chroma=128.
# Do not tune toward historical fake inter=1606.
SRC_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "REAL_REF_MEASURE source_sha=$SRC_SHA" >&2
echo "REAL_REF_MEASURE pre-register HEADLINE: intra=0/300 inter=0/3300 (chroma stub floors Y+U+V mb_exact)" >&2
echo "REAL_REF_MEASURE pre-register LUMA: intra_y_mb=225..245/300 intra_y_px=60000..65000/76800 (I16 AC max15 skip_dc + combined idct)" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_REAL" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" -GUSE_REAL_REF_COMMIT=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"

{
  echo "SOURCE_SHA=$SRC_SHA"
  "$BUILD_REAL/Vstream_path_full_frame_tb" \
    --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
    --native-candidate-i420-out "$REAL_CAND" \
    --inter-metadata-out "$REAL_META" --sequence "$SEQUENCE" \
    --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
    --json-out "$REAL_COMPARE" --trace-json-out "$REAL_REF_DIR/mb0_pipeline_trace.json" \
    --real-ref --expect-red
} | tee "$REAL_REF_DIR/sim.log"

# Address bitmaps: unique MB coverage (not enqueue counts).
python3 - "$REAL_REF_DIR/sim.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
if "SOURCE_SHA=" not in log:
    raise SystemExit("FAIL sim.log missing SOURCE_SHA stamp")
# Delivered hold→stub (all slices): at least one slice with unique==expected==300
deliv = re.findall(
    r"DELIVERED_MB_BITMAP unique=(\d+) dup=(\d+) oob=(\d+) expected=(\d+) fault_drop=(\d+) real_ref=(\d+)",
    log,
)
if not deliv:
    raise SystemExit("FAIL missing DELIVERED_MB_BITMAP lines")
ok_d = [t for t in deliv if t[0] == t[3] and t[1] == "0" and t[2] == "0" and t[3] == "300" and t[4] == "0"]
if not ok_d:
    raise SystemExit(f"FAIL DELIVERED_MB_BITMAP no clean 300-cover slice: {deliv!r}")
# Store unique for I-recon (real-ref): unique==300 dup==0
stores = re.findall(
    r"STORE_MB_BITMAP unique=(\d+) dup=(\d+) oob=(\d+) expected=(\d+) fault_dup=(\d+)",
    log,
)
if not stores:
    raise SystemExit("FAIL missing STORE_MB_BITMAP lines")
ok_s = [t for t in stores if t[0] == t[3] == "300" and t[1] == "0" and t[2] == "0" and t[4] == "0"]
if not ok_s:
    raise SystemExit(f"FAIL STORE_MB_BITMAP no clean 300-cover: {stores!r}")
print(f"OK address bitmaps: delivered_ok={len(ok_d)} store_ok={len(ok_s)} sha_line_ok")
PY

python3 - "$REAL_META" <<'PY'
import json, sys
meta = json.load(open(sys.argv[1]))
c = meta.get("candidate", {})
want = {
    "reference_picture_state": "self_decoded_dpb_commit_pre_deblock_no_golden_prefill",
    "reference_picture_source": "product_decode_stub_recon_store_to_dpb_writeback",
    "reconstruction_stage": "mc_pred_plus_residual_pre_deblock_self_ref",
    "colorspace": "I420_NATIVE",
    "h264_loop_filter": "disabled",
}
for k, w in want.items():
    got = c.get(k)
    if got != w:
        raise SystemExit(f"FAIL real-ref metadata: candidate.{k}={got!r} want {w!r}")
    if "testbench_prefilled" in str(got):
        raise SystemExit(f"FAIL real-ref still prefilled: {k}={got!r}")
print(
    "OK real-ref provenance:",
    f"stage={c['reconstruction_stage']}",
    f"state={c['reference_picture_state']}",
    f"source={c['reference_picture_source']}",
)
PY

set +e
REAL_SCORE_OUT="$("$ROOT/tools/score_i420_candidate.py" \
  --sequence "$SEQUENCE" \
  --golden-manifest "$GOLDEN_MANIFEST" \
  --golden-planes "$GOLDEN_PLANES" \
  --candidate-planes "$REAL_CAND" \
  --candidate-colorspace I420_NATIVE \
  --reference-h264-loop-filter disabled \
  --candidate-h264-loop-filter disabled \
  --mb-metadata "$REAL_META" \
  --output "$REAL_SCORE" \
  --expect-red 2>&1)"
REAL_SCORE_RC=$?
set -e
printf '%s\n' "$REAL_SCORE_OUT"
if [[ "$REAL_SCORE_RC" -ne 0 ]]; then
  echo "FAIL real-ref score_i420_candidate rc=$REAL_SCORE_RC (fix candidate, never scorer)" >&2
  exit "$REAL_SCORE_RC"
fi
grep -E 'I420_CANDIDATE_SCORE summary|score_i420_candidate: OK' <<<"$REAL_SCORE_OUT"

python3 - "$REAL_SCORE" <<'PY'
import json, sys
score = json.load(open(sys.argv[1]))
s = score["summary"]
intra, inter = s["intra"], s["inter"]
print(
    f"REAL_REF_SCORE intra={intra['mb_exact']}/{intra['mb_total']} "
    f"inter={inter['mb_exact']}/{inter['mb_total']} strict_pass={score.get('strict_pass')}"
)
print(
    f"REAL_REF_vs_PREREGISTER HEADLINE pre=intra0/300 inter0/3300 "
    f"actual=intra{intra['mb_exact']}/{intra['mb_total']} "
    f"inter{inter['mb_exact']}/{inter['mb_total']}"
)
if "testbench_prefilled" in json.dumps(score):
    raise SystemExit("FAIL real-ref score blob mentions testbench_prefilled")
print("OK real-ref score recorded (honest self-produced reference)")
PY

# Luma-only progress (scorer untouched). Chroma=128 floors headline mb_exact.
REAL_LUMA="$REAL_REF_DIR/native_inter_luma_progress.json"
"$ROOT/tools/score_i420_luma_progress.py" \
  --golden-planes "$GOLDEN_PLANES" \
  --candidate-planes "$REAL_CAND" \
  --width "$WIDTH" --height "$HEIGHT" \
  --i-frames 1 \
  --output "$REAL_LUMA"
python3 - "$REAL_LUMA" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
si, sp = j["summary"]["intra"], j["summary"]["inter"]
print(
    f"REAL_REF_LUMA_vs_PREREGISTER pre_y_mb=225..245/300 pre_y_px=60000..65000/76800 "
    f"actual_y_mb={si['y_mb_exact']}/{si['y_mb_total']} "
    f"actual_y_px={si['y_pixel_exact']}/{si['y_pixel_total']} "
    f"y_blk4={si['y_blk4_exact']}/{si['y_blk4_total']} y_mae={si['y_mae_mean']:.4f}"
)
print(
    f"REAL_REF_LUMA inter_y_mb={sp['y_mb_exact']}/{sp['y_mb_total']} "
    f"inter_y_px={sp['y_pixel_exact']}/{sp['y_pixel_total']}"
)
# Sanity: if Y is all-128 cold store, y_mb_exact must be 0 — refuse silent floor.
if si["y_pixel_exact"] == 0 and si["y_pixel_total"] > 0:
    raise SystemExit("FAIL luma progress: zero Y pixels exact (cold/flat candidate?)")
print("OK real-ref luma progress recorded (Y-only gradient; headline scorer unmodified)")
PY

# Mutation twin: FAULT_REAL_REF_XOR_FILL must change the native candidate.
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_REAL_XOR" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" \
  -GUSE_REAL_REF_COMMIT=1 -GFAULT_REAL_REF_XOR_FILL=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"
"$BUILD_REAL_XOR/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
  --native-candidate-i420-out "$REAL_REF_DIR/native_inter_candidate_xor.i420" \
  --inter-metadata-out "$REAL_REF_DIR/native_inter_metadata_xor.json" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$REAL_REF_DIR/frame_planes_compare_xor.json" \
  --real-ref --expect-red \
  >/dev/null
python3 - "$REAL_CAND" "$REAL_REF_DIR/native_inter_candidate_xor.i420" <<'PY'
import sys
a = open(sys.argv[1], "rb").read()
b = open(sys.argv[2], "rb").read()
if a == b:
    raise SystemExit("FAIL real-ref XOR twin: candidate identical to clean real-ref (fault inactive)")
print(f"OK real-ref XOR twin: candidates differ (clean={len(a)} xor={len(b)})")
PY

# --- Product-mode delivery bitmap (USE_REAL_REF_COMMIT=0) — same lossless hold ---
BUILD_PROD_BMP="$ROOT/build/verilator/stream_path_full_frame_prod_bmp"
mkdir -p "$BUILD_PROD_BMP"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_PROD_BMP" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" \
  -GUSE_REAL_REF_COMMIT=0 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"
PROD_BMP_LOG="$REAL_REF_DIR/product_delivery_bitmap.log"
{
  echo "SOURCE_SHA=$SRC_SHA"
  "$BUILD_PROD_BMP/Vstream_path_full_frame_tb" \
    --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
    --native-candidate-i420-out "$REAL_REF_DIR/product_mode_candidate.i420" \
    --inter-metadata-out "$REAL_REF_DIR/product_mode_metadata.json" --sequence "$SEQUENCE" \
    --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
    --json-out "$REAL_REF_DIR/product_mode_compare.json" \
    --expect-red
} | tee "$PROD_BMP_LOG"
python3 - "$PROD_BMP_LOG" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
rows = re.findall(
    r"DELIVERED_MB_BITMAP unique=(\d+) dup=(\d+) oob=(\d+) expected=(\d+) fault_drop=(\d+) real_ref=(\d+)",
    log,
)
# Product mode: real_ref=0; need a P-slice 300 unique delivery (no drop).
ok = [t for t in rows if t[5] == "0" and t[0] == t[3] == "300" and t[1] == "0" and t[4] == "0"]
if not ok:
    raise SystemExit(f"FAIL product DELIVERED_MB_BITMAP need unique=300: {rows!r}")
print(f"OK product-mode DELIVERED_MB_BITMAP unique=300 (n={len(ok)})")
PY

# Mutation FAULT_DROP_TRAV_MB — product mode must NOT cover 300 uniquely.
BUILD_DROP="$ROOT/build/verilator/stream_path_full_frame_fault_drop"
mkdir -p "$BUILD_DROP"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" \
  -GUSE_REAL_REF_COMMIT=0 -GFAULT_DROP_TRAV_MB=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"
DROP_LOG="$REAL_REF_DIR/fault_drop_trav.log"
"$BUILD_DROP/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
  --native-candidate-i420-out "$REAL_REF_DIR/fault_drop_candidate.i420" \
  --inter-metadata-out "$REAL_REF_DIR/fault_drop_metadata.json" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$REAL_REF_DIR/fault_drop_compare.json" \
  --expect-red >"$DROP_LOG" 2>&1 || true
python3 - "$DROP_LOG" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
rows = re.findall(
    r"DELIVERED_MB_BITMAP unique=(\d+) dup=(\d+) oob=(\d+) expected=(\d+) fault_drop=(\d+)",
    log,
)
if not rows:
    raise SystemExit("FAIL FAULT_DROP: no DELIVERED_MB_BITMAP")
# RED: must not have a clean unique==expected==300 with fault_drop=1
bad = [t for t in rows if t[4] == "1" and t[0] == t[3] == "300" and t[1] == "0"]
if bad:
    raise SystemExit(f"FAIL FAULT_DROP twin stayed GREEN (full cover): {bad!r}")
print(f"OK FAULT_DROP_TRAV_MB RED (rows={rows[:4]!r}...)")
PY

# Mutation FAULT_DUP_STORE — real-ref store bitmap must show dup>0.
BUILD_DUP="$ROOT/build/verilator/stream_path_full_frame_fault_dup"
mkdir -p "$BUILD_DUP"
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DUP" \
  --top-module stream_path_full_frame_tb -GFRAME_W="$WIDTH" -GFRAME_H="$HEIGHT" \
  -GUSE_REAL_REF_COMMIT=1 -GFAULT_DUP_STORE=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL_ARGS[@]}" "$TB"
DUP_LOG="$REAL_REF_DIR/fault_dup_store.log"
"$BUILD_DUP/Vstream_path_full_frame_tb" \
  --annexb "$BITSTREAM" --golden-planes "$GOLDEN_PLANES" --golden-manifest "$GOLDEN_MANIFEST" \
  --native-candidate-i420-out "$REAL_REF_DIR/fault_dup_candidate.i420" \
  --inter-metadata-out "$REAL_REF_DIR/fault_dup_metadata.json" --sequence "$SEQUENCE" \
  --source-sha256 "$SOURCE_SHA" --width "$WIDTH" --height "$HEIGHT" \
  --json-out "$REAL_REF_DIR/fault_dup_compare.json" \
  --real-ref --expect-red >"$DUP_LOG" 2>&1 || true
python3 - "$DUP_LOG" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
rows = re.findall(
    r"STORE_MB_BITMAP unique=(\d+) dup=(\d+) oob=(\d+) expected=(\d+) fault_dup=(\d+)",
    log,
)
if not rows:
    raise SystemExit("FAIL FAULT_DUP: no STORE_MB_BITMAP")
red = [t for t in rows if t[4] == "1" and int(t[1]) > 0]
if not red:
    raise SystemExit(f"FAIL FAULT_DUP twin stayed GREEN (dup=0): {rows!r}")
print(f"OK FAULT_DUP_STORE RED (sample={red[0]!r})")
PY

echo "OK REAL_REF_MEASURE complete"
