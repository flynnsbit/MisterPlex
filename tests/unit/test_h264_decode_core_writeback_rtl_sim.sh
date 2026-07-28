#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_decode_core writeback simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_core.sv"
DPB_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_decode_core_wb_tb.sv"
TB="$ROOT/tests/rtl/h264_decode_core_wb_tb.cpp"
BUILD="$ROOT/build/verilator/h264_decode_core_wb"
BUILD_FAULT="$ROOT/build/verilator/h264_decode_core_wb_fault"

for f in "$RTL" "$DPB_RTL" "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_decode_core.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_decode_core.sv" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION (h264_decode_core writeback)" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_decode_core_wb_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$DPB_RTL" "$RTL" "$TB"
"$BUILD/Vh264_decode_core_wb_tb"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module h264_decode_core_wb_tb -Wno-fatal +define+H264_DECODE_CORE_FAULT_DROP_WB \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$DPB_RTL" "$RTL" "$TB"
set +e
FAULT_OUT="$("$BUILD_FAULT/Vh264_decode_core_wb_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL h264_decode_core writeback red-check: dropped writeback unexpectedly passed" >&2
  exit 1
fi
if ! grep -q 'write count' <<<"$FAULT_OUT"; then
  echo "FAIL h264_decode_core writeback red-check: expected write count diagnostic" >&2
  exit 1
fi
echo "OK h264_decode_core writeback red-check: dropped writeback fault failed scoreboard"
