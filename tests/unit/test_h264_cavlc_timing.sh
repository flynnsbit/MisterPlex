#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if (($# == 0)); then set -- 1 2 3; fi
for LANES in "$@"; do
  case "$LANES" in 1|2|3) ;; *) exit 2 ;; esac
  if ps -eo comm= | grep -qE '^quartus_(fit|map|sta|sh)$'; then
    printf 'Quartus process active; CAVLC simulation not launched\n' >&2
    exit 75
  fi
  BUILD="$ROOT/build/verilator/cavlc_timing_lanes$LANES"
  mkdir -p "$BUILD/compiler-scratch"
  export TMPDIR="$BUILD/compiler-scratch"
  sha256sum fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv \
    fpga/Plex_MiSTer/rtl/h264_cavlc_fast_vlc.svh \
    tests/frozen-rtl/h264_cavlc_residual_reference.sv \
    tests/rtl/h264_cavlc_residual_tb_top.sv tests/rtl/h264_cavlc_residual_tb.cpp \
    tests/cavlc-host/libmisterplex/*.hpp tests/unit/test_h264_cavlc_timing.sh \
    scripts/run_verilator.sh > "$BUILD/inputs.sha256"
  bash scripts/run_verilator.sh --cc --exe --build --assert -j 1 \
    --Mdir "$BUILD" --top-module h264_cavlc_residual_tb_top -Wno-fatal \
    -DCAVLC_LEVEL_LANES="$LANES" -DCAVLC_FAST_VLC_TEST=1 \
    -I"$ROOT/fpga/Plex_MiSTer/rtl" \
    -CFLAGS "-std=c++17 -O2 -DCAVLC_TEST_LANES=$LANES -DCAVLC_FAST_VLC_TEST=1 -I$ROOT/tests/cavlc-host" \
    "$ROOT/fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv" \
    "$ROOT/tests/frozen-rtl/h264_cavlc_residual_reference.sv" \
    "$ROOT/tests/rtl/h264_cavlc_residual_tb_top.sv" \
    "$ROOT/tests/rtl/h264_cavlc_residual_tb.cpp" > "$BUILD/build.log" 2>&1 || {
      tail -50 "$BUILD/build.log"; exit 1;
    }
  sha256sum "$BUILD/Vh264_cavlc_residual_tb_top" > "$BUILD/binary.sha256"
  "$BUILD/Vh264_cavlc_residual_tb_top" > "$BUILD/execution.log" 2>&1 || {
    tail -35 "$BUILD/execution.log"; exit 1;
  }
  sha256sum --check --status "$BUILD/inputs.sha256"
  printf 'CAVLC_LEVEL_LANES=%s\n' "$LANES"
  grep -E 'PASS|service_cycles' "$BUILD/execution.log"
done
