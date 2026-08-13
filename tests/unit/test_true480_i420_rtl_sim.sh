#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
RTL="${TRUE480_RTL_DIR:-$ROOT/fpga/Plex_MiSTer/rtl}"
MODE="${1:---gate}"
TAG="${TRUE480_BUILD_TAG:-repo}"
PRODUCT_FALLBACK_POLLS=4096
ACTIVE_CONFIG=0
if [[ "$MODE" == "--active-gate" ]]; then
  ACTIVE_CONFIG=1
  TAG="${TAG}_active"
fi
ACTIVE_VERILATOR_ARGS=()
ACTIVE_RUN_ARGS=()
PRESENT_EXTRA_SOURCES=()
PRESENT_CORE_SUPPORT=()

for source in present_npx_path.sv present_beam_ppc.sv present_content_window.sv \
              frame_store.sv present_beam_content_de.sv; do
  if [[ -f "$RTL/$source" ]]; then
    PRESENT_CORE_SUPPORT+=("$RTL/$source")
  fi
done

set +e
VERILATOR_VERSION="$("$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; true480 I420 proof was NOT run." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
if [[ ! -f "$RTL/ddr_frame_store.sv" ]]; then
  echo "RTL SIM ERROR: TRUE480_RTL_DIR has no ddr_frame_store.sv: $RTL" >&2
  exit 2
fi
if [[ "$ACTIVE_CONFIG" -eq 0 && "$MODE" == "--gate" &&
      -f "$RTL/present_beam_true_480p.sv" ]]; then
  echo "RTL SIM ERROR: refusing macro-OFF gate for active-capable RTL; use --active-gate" >&2
  exit 2
fi
if [[ "$ACTIVE_CONFIG" -eq 1 ]]; then
  for source in present_core.sv present_beam_true_480p.sv; do
    if [[ ! -f "$RTL/$source" ]]; then
      echo "RTL SIM ERROR: active true480 config requires $source: $RTL" >&2
      exit 2
    fi
  done
  if ! grep -Fq 'parameter int Y_FILL_STRIDE = 1' "$RTL/ddr_frame_store.sv"; then
    echo "RTL SIM ERROR: active true480 store lacks Y_FILL_STRIDE parameter: $RTL" >&2
    exit 2
  fi
  if ! grep -Fq '`ifdef PLEX_PRESENT_TRUE_480P' "$RTL/present_core.sv"; then
    echo "RTL SIM ERROR: active true480 present_core lacks product branch: $RTL" >&2
    exit 2
  fi
  ACTIVE_VERILATOR_ARGS=(+define+PLEX_PRESENT_TRUE_480P)
  ACTIVE_RUN_ARGS=(--require-active-config)
  PRESENT_EXTRA_SOURCES=("$RTL/present_beam_true_480p.sv")
fi

build_variant() {
  local name="$1"
  local fault="$2"
  local build="$ROOT/build/verilator/true480_i420_${TAG}_${name}"
  mkdir -p "$build"
  set +e
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build" \
    --top-module true480_i420_tb \
    -GGEOMETRY_FAULT="$fault" \
    -GSTALE_DOORBELL_FALLBACK_POLLS="$PRODUCT_FALLBACK_POLLS" \
    "${ACTIVE_VERILATOR_ARGS[@]}" \
    -I"$RTL" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/host -I$ROOT/tests/rtl" \
    "$ROOT/tests/rtl/true480_i420_tb_top.sv" \
    "$RTL/ddr_frame_store.sv" \
    "$RTL/line_buf_ram.sv" \
    "$RTL/async_fifo.sv" \
    "$ROOT/tests/rtl/true480_i420_tb.cpp" >"$build/build.log" 2>&1
  local rc=$?
  set -e
  echo "build_${name} true rc=$rc" >&2
  if [[ "$rc" -ne 0 ]]; then
    tail -120 "$build/build.log" >&2
    exit "$rc"
  fi
  printf '%s\n' "$build/Vtrue480_i420_tb"
}

build_present() {
  local build="$ROOT/build/verilator/true480_present_${TAG}"
  mkdir -p "$build"
  set +e
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build" \
    --top-module true480_present_tb \
    +define+DDR_FRAME_STORE \
    "${ACTIVE_VERILATOR_ARGS[@]}" \
    -I"$RTL" \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/host -I$ROOT/tests/rtl" \
    "$ROOT/tests/rtl/true480_present_tb_top.sv" \
    "$RTL/present_core.sv" \
    "${PRESENT_CORE_SUPPORT[@]}" \
    "$RTL/present_cadence.sv" \
    "$RTL/present_video_timing_720p.sv" \
    "$RTL/present_video_timing_960.sv" \
    "${PRESENT_EXTRA_SOURCES[@]}" \
    "$RTL/colorbars.sv" \
    "$RTL/ddr_frame_store.sv" \
    "$RTL/line_buf_ram.sv" \
    "$RTL/async_fifo.sv" \
    "$RTL/audio_tone.sv" \
    "$RTL/audio_fifo.sv" \
    "$ROOT/tests/rtl/true480_present_tb.cpp" >"$build/build.log" 2>&1
  local rc=$?
  set -e
  echo "build_present true rc=$rc" >&2
  if [[ "$rc" -ne 0 ]]; then
    tail -120 "$build/build.log" >&2
    exit "$rc"
  fi
  printf '%s\n' "$build/Vtrue480_present_tb"
}

run_pass() {
  local label="$1"
  shift
  set +e
  "$@"
  local rc=$?
  set -e
  echo "$label true rc=$rc"
  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL true480 control unexpectedly red: $label" >&2
    exit "$rc"
  fi
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
    echo "FAIL true480 red twin unexpectedly passed: $label" >&2
    exit 1
  fi
  if ! grep -Fq "$needle" <<<"$out"; then
    echo "FAIL true480 red twin lacked diagnostic '$needle': $label" >&2
    exit 1
  fi
  echo "PASS true480 red twin rejected: $label"
}

echo "RTL SIM: $VERILATOR_VERSION"
echo "TRUE480_RTL_DIR=$RTL"
echo "TRUE480_CONFIG=$([[ "$ACTIVE_CONFIG" -eq 1 ]] && echo active || echo legacy)"
if RTL_GIT_TOP="$(git -C "$RTL" rev-parse --show-toplevel 2>/dev/null)" &&
   [[ "$(realpath "$RTL")" == "$(realpath "$RTL_GIT_TOP/fpga/Plex_MiSTer/rtl")" ]]; then
  echo "TRUE480_RTL_HEAD=$(git -C "$RTL_GIT_TOP" rev-parse HEAD)"
fi
if [[ "$MODE" == "--calibrate-keepv22" || "$MODE" == "--calibrate-keepv27" ]]; then
  PRESENT="$(build_present)"
  run_pass "snapshot_${MODE#--calibrate-}" "$PRESENT" "$MODE"
  exit 0
fi
NORMAL="$(build_variant normal 0)"

run_pass "settled_full_frame_smoke" "$NORMAL" \
  "${ACTIVE_RUN_ARGS[@]}" --scenario smoke
run_pass "force_y_miss_black" "$NORMAL" \
  "${ACTIVE_RUN_ARGS[@]}" --scenario y-miss
run_pass "force_bad_bank_black" "$NORMAL" \
  "${ACTIVE_RUN_ARGS[@]}" --scenario bad-bank
run_pass "source_aspect_plxj_ack" "$NORMAL" \
  "${ACTIVE_RUN_ARGS[@]}" --scenario aspect-ack
run_pass "force_c_miss_stimulus" "$NORMAL" \
  "${ACTIVE_RUN_ARGS[@]}" --scenario c-miss-observe
run_red "legacy_store_y_2py" "row_identity unique_rows=240" \
  "$NORMAL" "${ACTIVE_RUN_ARGS[@]}" --scenario legacy

PILLAR="$(build_variant wrong_pillar 1)"
PILLAR_NEEDLE="exact_crop_pillars"
if [[ "$ACTIVE_CONFIG" -eq 1 ]]; then
  PILLAR_NEEDLE="true480 store contract mismatch"
fi
run_red "wrong_pillar" "$PILLAR_NEEDLE" \
  "$PILLAR" "${ACTIVE_RUN_ARGS[@]}" --scenario good
CROP="$(build_variant wrong_crop 2)"
run_red "wrong_crop" "exact_crop_pillars" \
  "$CROP" "${ACTIVE_RUN_ARGS[@]}" --scenario good

if [[ "$MODE" == "--controls-only" ]]; then
  echo "PASS true480 controls-only: fixture/DDR/Y-miss/bank/legacy/crop/pillar controls green"
  exit 0
fi
if [[ "$MODE" != "--gate" && "$MODE" != "--active-gate" ]]; then
  echo "usage: $0 [--gate|--active-gate|--controls-only|--calibrate-keepv22|--calibrate-keepv27]" >&2
  exit 2
fi

set +e
C_MISS_OUT="$("$NORMAL" "${ACTIVE_RUN_ARGS[@]}" --scenario c-miss 2>&1)"
C_MISS_RC=$?
set -e
printf '%s\n' "$C_MISS_OUT"
echo "force_c_miss_neutral_gray true rc=$C_MISS_RC"
if [[ "$C_MISS_RC" -ne 0 ]]; then
  if grep -Fq "required RTL behavior is hard-miss-on-Y only" <<<"$C_MISS_OUT"; then
    echo "BLOCKED true480 gate: RTL lacks soft-C neutral fallback (explicit Y/C hook proved the miss)" >&2
  fi
  exit "$C_MISS_RC"
fi
assert_sim_executed "true480_i420_c_miss" "$C_MISS_OUT" \
  "TRUE480_FORCE_C_MISS"
PRESENT="$(build_present)"
set +e
PRESENT_OUT="$("$PRESENT" "${ACTIVE_RUN_ARGS[@]}" 2>&1)"
PRESENT_RC=$?
set -e
printf '%s\n' "$PRESENT_OUT"
echo "present_full_frame_real_rate true rc=$PRESENT_RC"
if [[ "$PRESENT_RC" -ne 0 ]]; then
  echo "BLOCKED true480 gate: present_core is not native full-row 640x480 yet" >&2
  exit "$PRESENT_RC"
fi
assert_sim_executed "true480_present_full_frame" "$PRESENT_OUT" \
  "TRUE480_PRESENT output_rows=480"
echo "PASS true480 I420 RTL gate"
