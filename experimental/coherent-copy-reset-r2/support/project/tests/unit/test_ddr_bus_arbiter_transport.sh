#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="$ROOT/build/verilator/ddr_bus_arbiter_transport"
mkdir -p "$BUILD_ROOT"
sha256sum \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
  "$ROOT/tests/rtl/ddr_bus_arbiter_transport_tb.cpp" > "$BUILD_ROOT/inputs.sha256"
for block_ram in 0 1; do
  BUILD="$BUILD_ROOT/storage-$block_ram"
  mkdir -p "$BUILD/compiler-scratch"
  export TMPDIR="$BUILD/compiler-scratch"
  "$ROOT/scripts/run_verilator.sh" --cc --exe --build \
    --Mdir "$BUILD" --top-module ddr_bus_arbiter -GM1_HELD_REQUESTS=1 \
    -GM1_BLOCK_RAM="$block_ram" -Wno-fatal -CFLAGS "-std=c++17 -O2" \
    "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv" \
    "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" \
    "$ROOT/tests/rtl/ddr_bus_arbiter_transport_tb.cpp"
  "$BUILD/Vddr_bus_arbiter" | tee "$BUILD/result.txt"
  sha256sum --check --status "$BUILD_ROOT/inputs.sha256"
  sha256sum "$BUILD/Vddr_bus_arbiter" > "$BUILD/binary.sha256"
done
if ! cmp -s "$BUILD_ROOT/storage-0/result.txt" "$BUILD_ROOT/storage-1/result.txt"; then
  echo "FAIL held-request FIFO storage changed observable cycle timing" >&2
  exit 1
fi

READER_SOURCES=(
  "$ROOT/tests/rtl/ddr_reader_cdc_reset_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bitstream_reader.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/audio_session_ddr_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_transport_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_bus_arbiter.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)
sha256sum "${READER_SOURCES[@]}" "$ROOT/tests/rtl/ddr_reader_cdc_reset_tb.cpp" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_performance_clock.svh" \
  "$ROOT/tests/rtl/ddr_bitstream_ring_bfm.hpp" \
  "$ROOT/host/libmisterplex/ddr_bitstream_ring.hpp" \
  "$ROOT/host/libmisterplex/mailbox_abi_spec.hpp" > "$BUILD_ROOT/reader-inputs.sha256"
for drop_response in 0 1; do
  BUILD="$BUILD_ROOT/reader-reset-$drop_response"
  mkdir -p "$BUILD/compiler-scratch"
  export TMPDIR="$BUILD/compiler-scratch"
  "$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 1 \
    --Mdir "$BUILD" --top-module ddr_reader_cdc_reset_tb \
    -I"$ROOT/fpga/Plex_MiSTer/rtl" \
    -GDROP_RESET_RESPONSE="$drop_response" -Wno-fatal \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/host/libmisterplex -I$ROOT/tests/rtl" \
    "${READER_SOURCES[@]}" "$ROOT/tests/rtl/ddr_reader_cdc_reset_tb.cpp" \
    > "$BUILD/build.log" 2>&1 || { tail -n 60 "$BUILD/build.log"; exit 1; }
  if ((drop_response)); then
    if "$BUILD/Vddr_reader_cdc_reset_tb" > "$BUILD/result.txt" 2>&1; then
      echo "FAIL dropped reset-time response unexpectedly recovered" >&2
      exit 1
    fi
    if ! grep -q '^FAIL reader CDC reset: reset-time reader response lost$' "$BUILD/result.txt"; then
      tail -n 30 "$BUILD/result.txt" >&2
      exit 1
    fi
    echo "EXPECTED RED: dropping an owned reset-time response strands the reader"
  else
    "$BUILD/Vddr_reader_cdc_reset_tb" | tee "$BUILD/result.txt"
  fi
  sha256sum --check --status "$BUILD_ROOT/reader-inputs.sha256"
  sha256sum "$BUILD/Vddr_reader_cdc_reset_tb" > "$BUILD/binary.sha256"
done
