#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
echo "Scope: RTL product syntax parser, 1170/1170 MBs of one real 624x480 Baseline P frame, 300/300 real 320x240 IDR MBs, and MB0 16/16 intra4x4 modes"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_baseline_syntax real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_syntax_primitives.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_baseline_syntax_tb_top.sv"
TB="$ROOT/tests/rtl/h264_baseline_syntax_tb.cpp"
BUILD_ROOT="$ROOT/build/verilator"
BUILD_OK="$BUILD_ROOT/h264_baseline_syntax"
BUILD_FAULT="$BUILD_ROOT/h264_baseline_syntax_p8_fault"
BUILD_EPB_FAULT="$BUILD_ROOT/h264_baseline_syntax_epb_fault"
BUILD_I4_FAULT="$BUILD_ROOT/h264_baseline_syntax_i4_fault"

for f in "$RTL" "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_syntax_primitives.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_syntax_primitives.sv product RTL" >&2
  exit 2
fi

mkdir -p "$BUILD_OK" "$BUILD_FAULT" "$BUILD_EPB_FAULT" "$BUILD_I4_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_OK" \
  --top-module h264_baseline_syntax_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/host" \
  "$TOP" "$RTL" "$TB"
"$BUILD_OK/Vh264_baseline_syntax_tb_top"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module h264_baseline_syntax_tb_top -GFAULT_RARE_P8X8=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/host" \
  "$TOP" "$RTL" "$TB"
set +e
FAULT_OUT="$("$BUILD_FAULT/Vh264_baseline_syntax_tb_top" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL h264_baseline_syntax red-check: rare P8x8 fault unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'rare P8x8 partition' <<<"$FAULT_OUT"; then
  echo "FAIL h264_baseline_syntax red-check: rare P8x8 fault did not trip partition check" >&2
  exit 1
fi
echo "OK h264_baseline_syntax red-check: rare P8x8 perturbation failed partition check"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_I4_FAULT" \
  --top-module h264_baseline_syntax_tb_top -GFAULT_I4_MODE=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -I$ROOT/host" \
  "$TOP" "$RTL" "$TB"
set +e
I4_FAULT_OUT="$("$BUILD_I4_FAULT/Vh264_baseline_syntax_tb_top" 2>&1)"
I4_FAULT_RC=$?
set -e
printf '%s\n' "$I4_FAULT_OUT"
if [[ "$I4_FAULT_RC" -eq 0 ]]; then
  echo "FAIL h264_baseline_syntax red-check: intra4x4 mode fault unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'I MB0 intra4x4 mode mismatch' <<<"$I4_FAULT_OUT"; then
  echo "FAIL h264_baseline_syntax red-check: intra4x4 mode fault did not trip MB0 mode check" >&2
  exit 1
fi
echo "OK h264_baseline_syntax red-check: intra4x4 mode perturbation failed MB0 mode check"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_EPB_FAULT" \
  --top-module h264_baseline_syntax_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2 -DFAULT_SKIP_EPB=1 -I$ROOT/host" \
  "$TOP" "$RTL" "$TB"
set +e
EPB_FAULT_OUT="$("$BUILD_EPB_FAULT/Vh264_baseline_syntax_tb_top" 2>&1)"
EPB_FAULT_RC=$?
set -e
printf '%s\n' "$EPB_FAULT_OUT"
if [[ "$EPB_FAULT_RC" -eq 0 ]]; then
  echo "FAIL h264_baseline_syntax red-check: EPB removal fault unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'EPB removal failed before SPS/RBSP syntax parse' <<<"$EPB_FAULT_OUT"; then
  echo "FAIL h264_baseline_syntax red-check: EPB removal fault did not trip RBSP check" >&2
  exit 1
fi
echo "OK h264_baseline_syntax red-check: skipping EPB removal failed RBSP check"
