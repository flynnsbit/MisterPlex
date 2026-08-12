#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="${TRUE480_SHARED_RTL_DIR:-${TRUE480_RTL_DIR:-$ROOT/fpga/Plex_MiSTer/rtl}}"
MODE="${1:---gate}"
TAG="${TRUE480_SHARED_BUILD_TAG:-repo}"
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
  local build="$ROOT/build/verilator/true480_shared_${TAG}_${name}"
  mkdir -p "$build"
  set +e
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build" \
    --top-module true480_shared_ddr_tb \
    -GLINE_COUNT="$lines" \
    "${ACTIVE_VERILATOR_ARGS[@]}" \
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

echo "RTL SIM: $VERILATOR_VERSION"
echo "TRUE480_SHARED_RTL_DIR=$RTL"
echo "TRUE480_SHARED_CONFIG=$([[ "$ACTIVE_CONFIG" -eq 1 ]] && echo active || echo legacy)"
if RTL_GIT_TOP="$(git -C "$RTL" rev-parse --show-toplevel 2>/dev/null)" &&
   [[ "$(realpath "$RTL")" == "$(realpath "$RTL_GIT_TOP/fpga/Plex_MiSTer/rtl")" ]]; then
  echo "TRUE480_SHARED_RTL_HEAD=$(git -C "$RTL_GIT_TOP" rev-parse HEAD)"
fi
NORMAL="$(build_variant normal 8)"
run_red "idealized_DDR" "idealized_DDR_refused" \
  "$NORMAL" "${ACTIVE_RUN_ARGS[@]}" --ideal-ddr

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
PROOF_OUT="$("$NORMAL" "${ACTIVE_RUN_ARGS[@]}" 2>&1)"
PROOF_RC=$?
set -e
printf '%s\n' "$PROOF_OUT"
echo "shared_real_arbiter_stride1_480 true rc=$PROOF_RC"
if [[ "$PROOF_RC" -ne 0 ]]; then
  echo "BLOCKED true480 shared gate: real arbiter/nonideal DDR/STREAM proof is RED" >&2
  exit "$PROOF_RC"
fi
echo "PASS true480 shared-DDR fit-blocking simulation"
