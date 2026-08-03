#!/usr/bin/env bash
# ddr_frame_store qword export multi-lane free-lunch — red-before-green.
# GREEN: lanes 0..3 from one Y qword match single-pixel RGB.
# RED: FAULT_QWORD_LANE0 always picks byte0 → must FAIL green expectations
#      (script expects red binary to report PASS red-check).
# Soft-skip≠PASS. true rc direct.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: sim did not EXECUTE expected marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only or empty run is not a pass (soft-skip≠PASS)" >&2
    exit 2
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
fi
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator --version failed rc=$VERILATOR_RC" >&2
  exit 3
fi

BUILD_G="$ROOT/build/verilator/ddr_qword_export_green"
BUILD_R="$ROOT/build/verilator/ddr_qword_export_red"
mkdir -p "$BUILD_G" "$BUILD_R"

COMMON=(
  -cc --exe --build -j 4
  --top-module ddr_frame_store_qword_export_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  +define+DDR_FRAME_STORE_EXPORT_QWORDS
  "$ROOT/tests/rtl/ddr_frame_store_qword_export_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/tests/rtl/ddr_frame_store_qword_export_tb.cpp"
)

echo "=== GREEN build+run qword export ==="
set +e
"$RUN_VERILATOR" "${COMMON[@]}" -Mdir "$BUILD_G" >"$BUILD_G/build.log" 2>&1
BRC=$?
set -e
if [[ "$BRC" -ne 0 ]]; then
  tail -50 "$BUILD_G/build.log" >&2
  echo "FAIL green build true rc=$BRC" >&2
  exit "$BRC"
fi
set +e
GOUT="$("$BUILD_G/Vddr_frame_store_qword_export_tb" 2>&1)"
GRC=$?
set -e
echo "$GOUT"
assert_sim_executed "green" "$GOUT" \
  "CASE export_capture EXECUTED" \
  "PASS Y qword gradient discriminator" \
  "CASE lane0 EXECUTED" \
  "CASE lane3 EXECUTED" \
  "PASS green multi-lane free-lunch" \
  "QWORD_EXPORT_GREEN_DONE"
if [[ "$GRC" -ne 0 ]]; then
  echo "FAIL green qword export true rc=$GRC" >&2
  exit "$GRC"
fi
echo "OK green qword export true rc=0"

echo "=== RED twin FAULT_QWORD_LANE0 ==="
set +e
"$RUN_VERILATOR" "${COMMON[@]}" -Mdir "$BUILD_R" \
  -CFLAGS "-DDDR_FRAME_STORE_FAULT_QWORD_LANE0" >"$BUILD_R/build.log" 2>&1
RBRC=$?
set -e
if [[ "$RBRC" -ne 0 ]]; then
  tail -50 "$BUILD_R/build.log" >&2
  echo "FAIL red build true rc=$RBRC" >&2
  exit "$RBRC"
fi
set +e
ROUT="$("$BUILD_R/Vddr_frame_store_qword_export_tb" 2>&1)"
RRC=$?
set -e
echo "$ROUT"
assert_sim_executed "red" "$ROUT" \
  "CASE export_capture EXECUTED" \
  "PASS red-check FAULT_QWORD_LANE0" \
  "QWORD_EXPORT_RED_DONE"
if [[ "$RRC" -ne 0 ]]; then
  echo "FAIL red qword export true rc=$RRC" >&2
  exit "$RRC"
fi
echo "OK red qword export true rc=0"

echo "ALL OK ddr_qword_export RBG true rc=0"
exit 0
