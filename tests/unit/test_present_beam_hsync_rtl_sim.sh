#!/usr/bin/env bash
# Exact HSync/VSync pulse width + count for present_beam_content_de.
# L4 1280×720 H=1312 and 320×240-class H=400. Fails on rd-duck #1 (HSync=0).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing SKIP-as-pass" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

echo "RTL SIM: using $VERILATOR_VERSION" >&2
B="$ROOT/build/verilator/present_beam_hsync"
mkdir -p "$B"
"$RUN_VERILATOR" --cc --exe --build --Mdir "$B" \
  --top-module present_beam_hsync_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/present_beam_hsync_tb_top.sv" \
  "$RTL/present_beam_content_de.sv" \
  "$ROOT/tests/rtl/present_beam_hsync_tb.cpp"

set +e
"$B/Vpresent_beam_hsync_tb_top"
RC=$?
set -e
echo "present_beam_hsync true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: present_beam_hsync failed" >&2
  exit "$RC"
fi
echo "PASS test_present_beam_hsync_rtl_sim"
exit 0
