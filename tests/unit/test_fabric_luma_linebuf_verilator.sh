#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/fabric_luma_linebuf.sv"
TOP="$ROOT/tests/rtl/fabric_luma_linebuf_tb_top.sv"
TB="$ROOT/tests/rtl/fabric_luma_linebuf_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
set +e
VER="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"; RC=$?
set -e
if [[ $RC -ne 0 ]]; then echo "RTL SIM ERROR: Verilator missing" >&2; exit 3; fi
BUILD="$ROOT/build/verilator/fabric_luma_linebuf_tb"
rm -rf "$BUILD"; mkdir -p "$BUILD"
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build --Mdir "$BUILD" \
  --top-module fabric_luma_linebuf_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" "$RTL" "$TOP" "$TB"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
set +e
OUT="$("$BUILD/Vfabric_luma_linebuf_tb_top" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "fabric_luma_linebuf_sim true rc=$RC"
exit "$RC"
