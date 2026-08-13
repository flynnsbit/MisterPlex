#!/usr/bin/env bash
# SPI-only multi-bank present (no doorbell) — proves start_req path after have_seq fix.
set -euo pipefail
assert_sim_executed() {
  local label="$1"; shift; local log="$1"; shift; local missing=0; local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: missing marker: $m" >&2; missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then exit 2; fi
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
BUILD="$ROOT/build/verilator/ddr_spi_kick"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl"
mkdir -p "$BUILD"
set +e; VOUT="$($RUN --version 2>&1)"; VRC=$?; set -e
if [[ "$VRC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && { echo "SKIP RTL SIM"; exit 77; }
  echo "RTL SIM ERROR: Verilator not found" >&2; exit 3
elif [[ "$VRC" -ne 0 ]]; then echo "RTL SIM ERROR: probe failed" >&2; exit 3; fi
$RUN -sv -cc --exe --build -Mdir "$BUILD" \
  -CFLAGS "-std=c++17 -O2" \
  -Wno-WIDTH -Wno-SELRANGE -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-UNSIGNED \
  -I"$RTL" --top-module ddr_frame_store_spi_kick_tb \
  "$TB/ddr_frame_store_spi_kick_tb_top.sv" \
  "$RTL/ddr_frame_store.sv" "$RTL/async_fifo.sv" "$RTL/line_buf_ram.sv" \
  "$TB/ddr_frame_store_spi_kick_tb.cpp" -o Vddr_frame_store_spi_kick_tb
set +e; OUT="$("$BUILD/Vddr_frame_store_spi_kick_tb" 2>&1)"; RC=$?; set -e
printf '%s\n' "$OUT"
assert_sim_executed "spi_kick" "$OUT" "summary spi_kick" "frames_done="
exit "$RC"
