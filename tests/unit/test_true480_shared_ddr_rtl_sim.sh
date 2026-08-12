#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="${TRUE480_SHARED_RTL_DIR:-${TRUE480_RTL_DIR:-$ROOT/fpga/Plex_MiSTer/rtl}}"
MODE="${1:---gate}"
TAG="${TRUE480_SHARED_BUILD_TAG:-repo}"
PRODUCT_FALLBACK_POLLS=4096
STRESS_FALLBACK_POLLS=256
DRIFT_FAULT_FALLBACK_POLLS=4095
CROSS_M0_TOLERANCE_BEATS=78
ACTIVE_CONFIG=0
if [[ "$MODE" == "--active-gate" ]]; then
  ACTIVE_CONFIG=1
  TAG="${TAG}_active"
fi
ACTIVE_VERILATOR_ARGS=()
ACTIVE_RUN_ARGS=()
ACTIVE_EXTRA_SOURCES=()

set +e
VERILATOR_VERSION="$("$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; shared-DDR proof was NOT run." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
for source in ddr_frame_store.sv ddr_bus_arbiter.sv line_buf_ram.sv async_fifo.sv; do
  if [[ ! -f "$RTL/$source" ]]; then
    echo "RTL SIM ERROR: TRUE480_SHARED_RTL_DIR lacks $source: $RTL" >&2
    exit 2
  fi
done
if [[ "$ACTIVE_CONFIG" -eq 0 && "$MODE" == "--gate" &&
      -f "$RTL/present_beam_true_480p.sv" ]]; then
  echo "RTL SIM ERROR: refusing macro-OFF shared gate for active-capable RTL; use --active-gate" >&2
  exit 2
fi
if [[ "$ACTIVE_CONFIG" -eq 1 ]]; then
  if [[ ! -f "$RTL/present_beam_true_480p.sv" ]]; then
    echo "RTL SIM ERROR: active shared gate requires present_beam_true_480p.sv: $RTL" >&2
    exit 2
  fi
  if ! grep -Fq 'parameter int Y_FILL_STRIDE = 1' "$RTL/ddr_frame_store.sv"; then
    echo "RTL SIM ERROR: active shared store lacks Y_FILL_STRIDE parameter: $RTL" >&2
    exit 2
  fi
  if ! grep -Fq '`ifdef PLEX_PRESENT_TRUE_480P' "$RTL/ddr_frame_store.sv"; then
    echo "RTL SIM ERROR: active shared store lacks product branch: $RTL" >&2
    exit 2
  fi
  ACTIVE_VERILATOR_ARGS=(+define+PLEX_PRESENT_TRUE_480P)
  ACTIVE_RUN_ARGS=(--require-active-config)
  ACTIVE_EXTRA_SOURCES=("$RTL/present_beam_true_480p.sv")
fi

build_variant() {
  local name="$1"
  local lines="$2"
  local fallback_polls="${3:-$PRODUCT_FALLBACK_POLLS}"
  local extra_define="${4:-}"
  local build="$ROOT/build/verilator/true480_shared_${TAG}_${name}"
  local variant_args=()
  if [[ -n "$extra_define" ]]; then
    variant_args=("$extra_define")
  fi
  mkdir -p "$build"
  set +e
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build" \
    --top-module true480_shared_ddr_tb \
    -GLINE_COUNT="$lines" \
    -GSTALE_DOORBELL_FALLBACK_POLLS="$fallback_polls" \
    "${ACTIVE_VERILATOR_ARGS[@]}" \
    "${variant_args[@]}" \
    -I"$RTL" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/host -I$ROOT/tests/rtl" \
    "$ROOT/tests/rtl/true480_shared_ddr_tb_top.sv" \
    "$RTL/ddr_frame_store.sv" \
    "$RTL/ddr_bus_arbiter.sv" \
    "$RTL/line_buf_ram.sv" \
    "$RTL/async_fifo.sv" \
    "${ACTIVE_EXTRA_SOURCES[@]}" \
    "$ROOT/tests/rtl/true480_shared_ddr_tb.cpp" >"$build/build.log" 2>&1
  local rc=$?
  set -e
  echo "build_shared_${name} true rc=$rc" >&2
  if [[ "$rc" -ne 0 ]]; then
    tail -120 "$build/build.log" >&2
    exit "$rc"
  fi
  printf '%s\n' "$build/Vtrue480_shared_ddr_tb"
}

run_red() {
  local label="$1"
  local needle="$2"
  shift 2
  set +e
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  set -e
  printf '%s\n' "$out"
  echo "$label true rc=$rc"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL true480 shared red twin unexpectedly passed: $label" >&2
    exit 1
  fi
  if ! grep -Fq "$needle" <<<"$out"; then
    echo "FAIL true480 shared red twin lacked '$needle': $label" >&2
    exit 1
  fi
  echo "PASS true480 shared red twin rejected: $label"
}

extract_metric() {
  local text="$1"
  local prefix="$2"
  local key="$3"
  awk -v prefix="$prefix" -v key="$key" '
    $1 == prefix {
      for (i = 2; i <= NF; ++i) {
        split($i, pair, "=")
        if (pair[1] == key)
          value = pair[2]
      }
    }
    END {
      if (value == "")
        exit 1
      print value
    }
  ' <<<"$text"
}

echo "RTL SIM: $VERILATOR_VERSION"
echo "TRUE480_SHARED_RTL_DIR=$RTL"
echo "TRUE480_SHARED_CONFIG=$([[ "$ACTIVE_CONFIG" -eq 1 ]] && echo active || echo legacy)"
echo "TRUE480_SHARED_FALLBACK_POLLS=$PRODUCT_FALLBACK_POLLS"
if RTL_GIT_TOP="$(git -C "$RTL" rev-parse --show-toplevel 2>/dev/null)" &&
   [[ "$(realpath "$RTL")" == "$(realpath "$RTL_GIT_TOP/fpga/Plex_MiSTer/rtl")" ]]; then
  echo "TRUE480_SHARED_RTL_HEAD=$(git -C "$RTL_GIT_TOP" rev-parse HEAD)"
fi
NORMAL="$(build_variant normal 8)"
run_red "idealized_DDR" "idealized_DDR_refused" \
  "$NORMAL" "${ACTIVE_RUN_ARGS[@]}" --ideal-ddr

if [[ "$ACTIVE_CONFIG" -eq 1 ]]; then
  FALLBACK_DRIFT="$(build_variant fallback_drift 8 "$DRIFT_FAULT_FALLBACK_POLLS")"
  run_red "product_fallback_drift" \
    "product fallback polls=$DRIFT_FAULT_FALLBACK_POLLS required=$PRODUCT_FALLBACK_POLLS" \
    "$FALLBACK_DRIFT" "${ACTIVE_RUN_ARGS[@]}" --resource-only
  FALLBACK_STRESS="$(build_variant fallback_stress 8 "$STRESS_FALLBACK_POLLS")"
  run_red "repeated_fallback_count" \
    "stress_unchanged_token_fallback got=1 required=0" \
    "$FALLBACK_STRESS" "${ACTIVE_RUN_ARGS[@]}" \
    --accelerated-fallback-stress --fault-repeated-fallback
  CLAMPED_LOOKAHEAD="$(build_variant clamped_lookahead 8 "$PRODUCT_FALLBACK_POLLS" \
    +define+DDR_FRAME_STORE_FAULT_CLAMP_LOOKAHEAD)"
  run_red "clamped_frame_lookahead" "settled_visible_soft_c_fallback" \
    "$CLAMPED_LOOKAHEAD" "${ACTIVE_RUN_ARGS[@]}"
fi

LINE4="$(build_variant line4 4)"
run_red "insufficient_line_depth" "M10K_depth line_count=4" \
  "$LINE4" "${ACTIVE_RUN_ARGS[@]}" --resource-only
LINE16="$(build_variant line16 16)"
run_red "excessive_M10K_depth" "M10K_depth line_count=16" \
  "$LINE16" "${ACTIVE_RUN_ARGS[@]}" --resource-only
run_red "excessive_M10K_budget" "M10K_budget estimate=192" \
  "$LINE16" "${ACTIVE_RUN_ARGS[@]}" --resource-only

if [[ "$MODE" == "--controls-only" ]]; then
  echo "PASS true480 shared controls: ideal DDR and LINE_COUNT 4/16 rejected"
  exit 0
fi
if [[ "$MODE" != "--gate" && "$MODE" != "--active-gate" ]]; then
  echo "usage: $0 [--gate|--active-gate|--controls-only]" >&2
  exit 2
fi

set +e
PRODUCT_START_NS="$(date +%s%N)"
PROOF_OUT="$("$NORMAL" "${ACTIVE_RUN_ARGS[@]}" 2>&1)"
PROOF_RC=$?
PRODUCT_END_NS="$(date +%s%N)"
set -e
printf '%s\n' "$PROOF_OUT"
echo "shared_real_arbiter_stride1_480 true rc=$PROOF_RC"
echo "TRUE480_SHARED_RUNTIME proof_mode=product runtime_ms=$(( (PRODUCT_END_NS - PRODUCT_START_NS) / 1000000 ))"
if [[ "$PROOF_RC" -ne 0 ]]; then
  echo "BLOCKED true480 shared gate: real arbiter/nonideal DDR/STREAM proof is RED" >&2
  exit "$PROOF_RC"
fi

if [[ "$ACTIVE_CONFIG" -eq 1 ]]; then
  set +e
  STRESS_START_NS="$(date +%s%N)"
  STRESS_OUT="$("$FALLBACK_STRESS" "${ACTIVE_RUN_ARGS[@]}" \
    --accelerated-fallback-stress 2>&1)"
  STRESS_RC=$?
  STRESS_END_NS="$(date +%s%N)"
  set -e
  printf '%s\n' "$STRESS_OUT"
  echo "shared_accelerated_fallback_256 true rc=$STRESS_RC"
  echo "TRUE480_SHARED_RUNTIME proof_mode=fallback_stress runtime_ms=$(( (STRESS_END_NS - STRESS_START_NS) / 1000000 ))"
  if [[ "$STRESS_RC" -ne 0 ]]; then
    echo "BLOCKED true480 shared gate: accelerated fallback boundedness proof is RED" >&2
    exit "$STRESS_RC"
  fi

  PRODUCT_M0="$(extract_metric "$PROOF_OUT" TRUE480_SHARED_DDR m0_beats)"
  PRODUCT_FIRES="$(extract_metric "$PROOF_OUT" TRUE480_REFILL_TELEMETRY fallback_fires)"
  PRODUCT_SAME="$(extract_metric "$PROOF_OUT" TRUE480_REFILL_TELEMETRY same_window_total)"
  PRODUCT_REDUNDANT_QWORDS="$(extract_metric "$PROOF_OUT" TRUE480_REFILL_TELEMETRY redundant_qword_beats)"
  STRESS_M0="$(extract_metric "$STRESS_OUT" TRUE480_SHARED_DDR m0_beats)"
  STRESS_SAME="$(extract_metric "$STRESS_OUT" TRUE480_REFILL_TELEMETRY same_window_total)"
  STRESS_REDUNDANT_QWORDS="$(extract_metric "$STRESS_OUT" TRUE480_REFILL_TELEMETRY redundant_qword_beats)"
  FALLBACK_FIRES="$(extract_metric "$STRESS_OUT" TRUE480_REFILL_TELEMETRY fallback_fires)"
  FALLBACK_LINES="$(extract_metric "$STRESS_OUT" TRUE480_REFILL_TELEMETRY fallback_attributed_lines)"
  FALLBACK_QWORDS="$(extract_metric "$STRESS_OUT" TRUE480_REFILL_TELEMETRY fallback_attributed_qword_beats)"

  if (( PRODUCT_FIRES != 0 || FALLBACK_FIRES != 0 )); then
    echo "FAIL true480 fallback cross-run unchanged token fired product_fires=$PRODUCT_FIRES stress_fires=$FALLBACK_FIRES" >&2
    exit 1
  fi
  M0_DELTA=$((STRESS_M0 - PRODUCT_M0))
  if (( M0_DELTA < 0 )); then
    M0_ABS_DELTA=$((-M0_DELTA))
  else
    M0_ABS_DELTA=$M0_DELTA
  fi
  if (( M0_ABS_DELTA > CROSS_M0_TOLERANCE_BEATS )); then
    echo "FAIL true480 fallback cross-run m0_decomposition product=$PRODUCT_M0 stress=$STRESS_M0 product_fires=$PRODUCT_FIRES stress_fires=$FALLBACK_FIRES delta=$M0_DELTA tolerance=$CROSS_M0_TOLERANCE_BEATS" >&2
    exit 1
  fi
  if (( STRESS_SAME != PRODUCT_SAME ||
        STRESS_REDUNDANT_QWORDS != PRODUCT_REDUNDANT_QWORDS )); then
    echo "FAIL true480 fallback cross-run duplicate_decomposition product_same=$PRODUCT_SAME stress_same=$STRESS_SAME product_redundant_qwords=$PRODUCT_REDUNDANT_QWORDS stress_redundant_qwords=$STRESS_REDUNDANT_QWORDS fallback_fires=$FALLBACK_FIRES" >&2
    exit 1
  fi
  echo "TRUE480_FALLBACK_CROSS product_m0=$PRODUCT_M0 stress_m0=$STRESS_M0 product_fallback_fires=$PRODUCT_FIRES stress_fallback_fires=$FALLBACK_FIRES stress_total_fallback_lines=$FALLBACK_LINES stress_total_fallback_qword_beats=$FALLBACK_QWORDS m0_delta=$M0_DELTA tolerance=$CROSS_M0_TOLERANCE_BEATS product_same_window=$PRODUCT_SAME stress_same_window=$STRESS_SAME product_redundant_qword_beats=$PRODUCT_REDUNDANT_QWORDS stress_redundant_qword_beats=$STRESS_REDUNDANT_QWORDS"
fi

echo "PASS true480 shared-DDR product and accelerated-fallback simulations"
