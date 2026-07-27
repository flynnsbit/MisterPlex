#!/usr/bin/env bash
# RTL simulation gate for h264_mc_interp — block-level MC interpolation engine.
# Runs Verilator simulation with exhaustive sub-position coverage and
# red-before-green fault injection checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_mc_interp real RTL simulation was NOT run.
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

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_mc_interp.sv"
TB="$ROOT/tests/rtl/h264_mc_interp_tb.cpp"
TOP="$ROOT/tests/rtl/h264_mc_interp_tb_top.sv"
REF_MODEL="$ROOT/tests/rtl/h264_mc_ref_model.h"
BUILD="$ROOT/build/verilator/h264_mc_interp"
BUILD_LUMA_FAULT="$ROOT/build/verilator/h264_mc_interp_bad_luma"
BUILD_CHROMA_FAULT="$ROOT/build/verilator/h264_mc_interp_bad_chroma"

for f in "$RTL" "$TB" "$TOP" "$REF_MODEL"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done

mkdir -p "$BUILD" "$BUILD_LUMA_FAULT" "$BUILD_CHROMA_FAULT"

echo "RTL SIM: using $VERILATOR_VERSION" >&2

# ---- Green build: nominal RTL ----
echo "--- Building h264_mc_interp (nominal) ---" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_mc_interp_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/rtl" \
  "$TOP" "$RTL" "$TB"

echo "--- Running h264_mc_interp (nominal) ---" >&2
"$BUILD/Vh264_mc_interp_tb"

# ---- Red check 1: bad luma rounding ----
echo "--- Building h264_mc_interp (FAULT_BAD_LUMA_ROUND) ---" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_LUMA_FAULT" \
  --top-module h264_mc_interp_tb -GFAULT_BAD_LUMA_ROUND=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/rtl" \
  "$TOP" "$RTL" "$TB"

set +e
FAULT_OUT="$("$BUILD_LUMA_FAULT/Vh264_mc_interp_tb" 2>&1)"
FAULT_RC=$?
set -e
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_mc_interp_bad_luma "$FAULT_RC" <<<"$FAULT_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$FAULT_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_mc_interp RTL red-check: bad luma rounding fault failed golden"

# ---- Red check 2: bad chroma weights ----
echo "--- Building h264_mc_interp (FAULT_BAD_CHROMA_WEIGHT) ---" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_CHROMA_FAULT" \
  --top-module h264_mc_interp_tb -GFAULT_BAD_CHROMA_WEIGHT=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/rtl" \
  "$TOP" "$RTL" "$TB"

set +e
FAULT_OUT="$("$BUILD_CHROMA_FAULT/Vh264_mc_interp_tb" 2>&1)"
FAULT_RC=$?
set -e
if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" h264_mc_interp_bad_chroma "$FAULT_RC" <<<"$FAULT_OUT" 2>&1)"; then
  printf '%s\n%s\n' "$RED_CHECK" "$FAULT_OUT" >&2
  exit 1
fi
printf '%s\n' "$RED_CHECK"
echo "OK h264_mc_interp RTL red-check: bad chroma weight fault failed golden"

# ---- Precision Red checks 3-6: spec-class defects ----
PRECISION_FAULTS=(
  "BAD_ROUND_OFFSET:h264_mc_interp_bad_round_offset:j-position rounding (256 vs 512)"
  "NO_INTERMEDIATE_CLIP:h264_mc_interp_no_intermediate_clip:intermediate clip before vertical"
  "QPEL_AVERAGE_DIR:h264_mc_interp_qpel_avg_dir:quarter-pel averaging direction"
  "CHROMA_WEIGHT_TRANSPOSE:h264_mc_interp_chroma_transpose:chroma weight dx/dy transpose"
)

for SPEC in "${PRECISION_FAULTS[@]}"; do
  IFS=: read -r PARAM RED_ID DESC <<<"$SPEC"
  BUILD_DIR="$ROOT/build/verilator/h264_mc_interp_fault_${PARAM}"
  mkdir -p "$BUILD_DIR"

  echo "--- Building h264_mc_interp (FAULT_${PARAM}) ---" >&2
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$BUILD_DIR" \
    --top-module h264_mc_interp_tb "-GFAULT_${PARAM}=1" -Wno-fatal \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/rtl" \
    "$TOP" "$RTL" "$TB"

  set +e
  FAULT_OUT="$("$BUILD_DIR/Vh264_mc_interp_tb" 2>&1)"
  FAULT_RC=$?
  set -e
  FAIL_COUNT=$(printf '%s' "$FAULT_OUT" | grep -c "^FAIL" || true)
  # Subtract 1 for the summary "N failures out of M tests" line
  FAIL_COUNT=$((FAIL_COUNT > 0 ? FAIL_COUNT - 1 : 0))
  if ! RED_CHECK="$(python3 "$ROOT/tests/unit/expected_red.py" "$RED_ID" "$FAULT_RC" <<<"$FAULT_OUT" 2>&1)"; then
    printf '%s\n%s\n' "$RED_CHECK" "$FAULT_OUT" >&2
    exit 1
  fi
  printf '%s\n' "$RED_CHECK"
  echo "OK h264_mc_interp RTL red-check: ${DESC} fault — ${FAIL_COUNT}/953 detected"
done
