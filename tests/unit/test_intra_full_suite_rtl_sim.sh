#!/usr/bin/env bash
# Full-suite REAL RTL sim: I4x4 (~4600) + iq_idct_seq vs parallel (~3000).
# SKIP is NOT PASS. Never set ALLOW_MISSING_VERILATOR=1 to greenwash.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to report PASS." >&2
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP (ALLOW_MISSING_VERILATOR=1) — NOT A PASS" >&2
    exit 0
  fi
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/intra_full_suite"
mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module intra_full_suite_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/intra_full_suite_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_intra_pred.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_seq.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_transform_dc.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv" \
  "$ROOT/tests/rtl/intra_full_suite_tb.cpp"

"$BUILD/Vintra_full_suite_tb_top"
echo "OK test_intra_full_suite_rtl_sim"
