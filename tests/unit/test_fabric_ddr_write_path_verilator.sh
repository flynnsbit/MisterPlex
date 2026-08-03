#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
set +e; V="$("$RUN" --version 2>&1)"; RC=$?; set -e
if [[ $RC -ne 0 ]]; then echo "RTL SIM ERROR" >&2; exit 3; fi
B="$ROOT/build/verilator/fabric_ddr_write_path_tb"
rm -rf "$B"; mkdir -p "$B"
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN" --cc --exe --build +incdir+$ROOT/fpga/Plex_MiSTer/rtl --Mdir "$B" \
  --top-module fabric_ddr_write_path_tb_top -Wno-fatal -Wno-WIDTHEXPAND \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_writer.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_i420_pattern_src.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/fabric_ddr_write_path.sv" \
  "$ROOT/tests/rtl/fabric_ddr_write_path_tb_top.sv" \
  "$ROOT/tests/rtl/fabric_ddr_write_path_tb.cpp"
source "$ROOT/tests/unit/lib_rtl_sim_gate.sh"
set +e; OUT="$("$B/Vfabric_ddr_write_path_tb_top" 2>&1)"; RC=$?; set -e
printf '%s\n' "$OUT"
echo "fabric_ddr_write_path_sim true rc=$RC"
exit "$RC"
