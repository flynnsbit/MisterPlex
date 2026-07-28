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
SKIP RTL SIM: Verilator not found; h264_decode_core P16x16 real-P simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

TOP="$ROOT/tests/rtl/h264_decode_core_p16z_tb.sv"
TB="$ROOT/tests/rtl/h264_decode_core_p16z_tb.cpp"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
BUILD="$ROOT/build/verilator/h264_decode_core_p16z"
BUILD_DROP_PRED="$ROOT/build/verilator/h264_decode_core_p16z_drop_pred"
BUILD_DROP_RES="$ROOT/build/verilator/h264_decode_core_p16z_drop_residual"
BUILD_PERTURB_MV="$ROOT/build/verilator/h264_decode_core_p16z_perturb_mv"
BUILD_BAD_RBSP="$ROOT/build/verilator/h264_decode_core_p16z_bad_rbsp"
BUILD_DROP_MV_NB="$ROOT/build/verilator/h264_decode_core_p16z_drop_mv_neighbor"
BUILD_DROP_SCHED_RES="$ROOT/build/verilator/h264_decode_core_p16z_drop_scheduled_residual"
BUILD_DROP_LAST_LUMA_RES="$ROOT/build/verilator/h264_decode_core_p16z_drop_last_luma_residual"
BUILD_DROP_LAST_CHROMA_RES="$ROOT/build/verilator/h264_decode_core_p16z_drop_last_chroma_residual"
BUILD_SWAP_SCHED_COEFF="$ROOT/build/verilator/h264_decode_core_p16z_swap_scheduled_coeff"
BUILD_SWAP_CHROMA_COEFF="$ROOT/build/verilator/h264_decode_core_p16z_swap_chroma_scheduled_coeff"
BUILD_SWAP_CHROMA_READ="$ROOT/build/verilator/h264_decode_core_p16z_swap_chroma_read"
BUILD_SWAP_CHROMA_RES="$ROOT/build/verilator/h264_decode_core_p16z_swap_chroma_residual"
RTL=(
  "$RTL_DIR/h264_syntax_primitives.sv"
  "$RTL_DIR/h264_cavlc_residual.sv"
  "$RTL_DIR/h264_iq_idct_4x4.sv"
  "$RTL_DIR/h264_intra_pred.sv"
  "$RTL_DIR/h264_intra_nb_ctx.sv"
  "$RTL_DIR/h264_decode_top.sv"
  "$RTL_DIR/h264_inter_pred.sv"
  "$RTL_DIR/h264_deblock.sv"
  "$RTL_DIR/h264_decode_core.sv"
  "$RTL_DIR/h264_dpb.sv"
)
for f in "$TOP" "$TB" "${RTL[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done

mkdir -p "$BUILD" "$BUILD_DROP_PRED" "$BUILD_DROP_RES" "$BUILD_PERTURB_MV" "$BUILD_BAD_RBSP" "$BUILD_DROP_MV_NB" "$BUILD_DROP_SCHED_RES" "$BUILD_DROP_LAST_LUMA_RES" "$BUILD_DROP_LAST_CHROMA_RES" "$BUILD_SWAP_SCHED_COEFF" "$BUILD_SWAP_CHROMA_COEFF" "$BUILD_SWAP_CHROMA_READ" "$BUILD_SWAP_CHROMA_RES"
echo "RTL SIM: using $VERILATOR_VERSION (h264_decode_core P16x16 real-P)" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
"$BUILD/Vh264_decode_core_p16z_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP_PRED" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_PRED \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
DROP_PRED_OUT="$($BUILD_DROP_PRED/Vh264_decode_core_p16z_tb 2>&1)"
DROP_PRED_RC=$?
set -e
printf '%s\n' "$DROP_PRED_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_drop_pred "$DROP_PRED_RC" <<<"$DROP_PRED_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_PRED_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: dropped prediction fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP_RES" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_RESIDUAL \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
DROP_RES_OUT="$($BUILD_DROP_RES/Vh264_decode_core_p16z_tb 2>&1)"
DROP_RES_RC=$?
set -e
printf '%s\n' "$DROP_RES_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_drop_residual "$DROP_RES_RC" <<<"$DROP_RES_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_RES_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: dropped residual fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_PERTURB_MV" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_PERTURB_MV \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
PERTURB_MV_OUT="$($BUILD_PERTURB_MV/Vh264_decode_core_p16z_tb 2>&1)"
PERTURB_MV_RC=$?
set -e
printf '%s\n' "$PERTURB_MV_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_perturb_mv "$PERTURB_MV_RC" <<<"$PERTURB_MV_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$PERTURB_MV_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: perturbed MV fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_BAD_RBSP" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_BAD_RBSP_REQ \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
BAD_RBSP_OUT="$($BUILD_BAD_RBSP/Vh264_decode_core_p16z_tb 2>&1)"
BAD_RBSP_RC=$?
set -e
printf '%s\n' "$BAD_RBSP_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_bad_rbsp_req "$BAD_RBSP_RC" <<<"$BAD_RBSP_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$BAD_RBSP_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: bad RBSP request fault failed syntax scoreboard"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP_MV_NB" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_MV_NEIGHBOR \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
DROP_MV_NB_OUT="$($BUILD_DROP_MV_NB/Vh264_decode_core_p16z_tb 2>&1)"
DROP_MV_NB_RC=$?
set -e
printf '%s\n' "$DROP_MV_NB_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_drop_mv_neighbor "$DROP_MV_NB_RC" <<<"$DROP_MV_NB_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_MV_NB_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: dropped MV neighbor fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP_SCHED_RES" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_SCHEDULED_RESIDUAL \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
DROP_SCHED_RES_OUT="$($BUILD_DROP_SCHED_RES/Vh264_decode_core_p16z_tb 2>&1)"
DROP_SCHED_RES_RC=$?
set -e
printf '%s\n' "$DROP_SCHED_RES_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_drop_scheduled_residual "$DROP_SCHED_RES_RC" <<<"$DROP_SCHED_RES_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_SCHED_RES_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: dropped scheduled residual fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP_LAST_LUMA_RES" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_LAST_LUMA_RESIDUAL \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
DROP_LAST_LUMA_RES_OUT="$($BUILD_DROP_LAST_LUMA_RES/Vh264_decode_core_p16z_tb 2>&1)"
DROP_LAST_LUMA_RES_RC=$?
set -e
printf '%s\n' "$DROP_LAST_LUMA_RES_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_drop_last_luma_residual "$DROP_LAST_LUMA_RES_RC" <<<"$DROP_LAST_LUMA_RES_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_LAST_LUMA_RES_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: dropped last luma residual fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DROP_LAST_CHROMA_RES" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_LAST_CHROMA_RESIDUAL \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
DROP_LAST_CHROMA_RES_OUT="$($BUILD_DROP_LAST_CHROMA_RES/Vh264_decode_core_p16z_tb 2>&1)"
DROP_LAST_CHROMA_RES_RC=$?
set -e
printf '%s\n' "$DROP_LAST_CHROMA_RES_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_drop_last_chroma_residual "$DROP_LAST_CHROMA_RES_RC" <<<"$DROP_LAST_CHROMA_RES_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$DROP_LAST_CHROMA_RES_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: dropped last chroma residual fault failed exact samples"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SWAP_SCHED_COEFF" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_SWAP_SCHEDULED_COEFF \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
SWAP_SCHED_COEFF_OUT="$($BUILD_SWAP_SCHED_COEFF/Vh264_decode_core_p16z_tb 2>&1)"
SWAP_SCHED_COEFF_RC=$?
set -e
printf '%s\n' "$SWAP_SCHED_COEFF_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_swap_scheduled_coeff "$SWAP_SCHED_COEFF_RC" <<<"$SWAP_SCHED_COEFF_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SWAP_SCHED_COEFF_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: swapped scheduled coefficient fault failed scan-order scoreboard"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SWAP_CHROMA_COEFF" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_SWAP_CHROMA_SCHEDULED_COEFF \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
SWAP_CHROMA_COEFF_OUT="$($BUILD_SWAP_CHROMA_COEFF/Vh264_decode_core_p16z_tb 2>&1)"
SWAP_CHROMA_COEFF_RC=$?
set -e
printf '%s\n' "$SWAP_CHROMA_COEFF_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_swap_chroma_scheduled_coeff "$SWAP_CHROMA_COEFF_RC" <<<"$SWAP_CHROMA_COEFF_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SWAP_CHROMA_COEFF_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: swapped chroma coefficient fault failed scan-order scoreboard"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SWAP_CHROMA_READ" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_SWAP_CHROMA_READ \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
SWAP_CHROMA_READ_OUT="$($BUILD_SWAP_CHROMA_READ/Vh264_decode_core_p16z_tb 2>&1)"
SWAP_CHROMA_READ_RC=$?
set -e
printf '%s\n' "$SWAP_CHROMA_READ_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_swap_chroma_read "$SWAP_CHROMA_READ_RC" <<<"$SWAP_CHROMA_READ_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SWAP_CHROMA_READ_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: swapped chroma read fault failed U/V scoreboard"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_SWAP_CHROMA_RES" \
  --top-module h264_decode_core_p16z_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_SWAP_CHROMA_RESIDUAL \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "${RTL[@]}" "$TB"
set +e
SWAP_CHROMA_RES_OUT="$($BUILD_SWAP_CHROMA_RES/Vh264_decode_core_p16z_tb 2>&1)"
SWAP_CHROMA_RES_RC=$?
set -e
printf '%s\n' "$SWAP_CHROMA_RES_OUT"
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_decode_core_p16z_swap_chroma_residual "$SWAP_CHROMA_RES_RC" <<<"$SWAP_CHROMA_RES_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$SWAP_CHROMA_RES_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_decode_core p16x16 real-P red-check: swapped chroma residual fault failed U/V residual scoreboard"
