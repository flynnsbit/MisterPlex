#!/usr/bin/env bash
# Dual-geometry present path: Template 640×480 AND L4 1280×720 side-by-side.
# NEGATIVE: fault twin keeps H_DE=529 under MODE=1 — must be detected.
# Product QSF default-off is asserted; does not enable L4.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

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

DERIVED="$ROOT/fpga/Plex_MiSTer/rtl/present_geometry_derived.sv"
TOP="$ROOT/tests/rtl/present_geom_dual_tb_top.sv"
TB="$ROOT/tests/rtl/present_geom_dual_tb.cpp"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"
# Product-path structural gates: test_present_hardcode_sweep.py (not this bench).

for f in "$DERIVED" "$TOP" "$TB" "$QSF"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing $f" >&2
    exit 2
  fi
done

# Product default must stay off.
if grep -E '^[^#]*PLEX_PRESENT_720P_L4=1' "$QSF" >/dev/null; then
  echo "RTL SIM ERROR: product QSF has PLEX_PRESENT_720P_L4 active — default-off violated" >&2
  exit 2
fi
if ! grep -E '^set_global_assignment -name VERILOG_MACRO "FRAME_W=640"' "$QSF" >/dev/null \
  || ! grep -E '^set_global_assignment -name VERILOG_MACRO "FRAME_H=480"' "$QSF" >/dev/null; then
  echo "RTL SIM ERROR: product FRAME_W/H not 640/480" >&2
  exit 2
fi

echo "RTL SIM: using $VERILATOR_VERSION" >&2
BUILD="$ROOT/build/verilator/present_geom_dual"
mkdir -p "$BUILD"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module present_geom_dual_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$DERIVED" "$TB"

set +e
"$BUILD/Vpresent_geom_dual_tb_top"
RC=$?
set -e
echo "present_geom_dual true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: dual-geometry TB failed" >&2
  exit "$RC"
fi

echo "PASS present_geom_dual_rtl_sim"
exit 0
