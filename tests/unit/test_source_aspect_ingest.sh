#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
BUILD="$ROOT/build/verilator/source_aspect_ingest"

mkdir -p "$BUILD"
"$RUN_VERILATOR" --cc --exe --build --Mdir "$BUILD" \
  --top-module source_aspect_ingest_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$ROOT/tests/rtl/source_aspect_ingest_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/source_aspect_ingest.sv" \
  "$ROOT/tests/rtl/source_aspect_ingest_tb.cpp"

"$BUILD/Vsource_aspect_ingest_tb_top"
