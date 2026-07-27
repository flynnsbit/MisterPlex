#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to report PASS." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL_SCHED="$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock_scheduler.sv"
RTL_DEBLOCK="$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_deblock_mb_sched_tb_top.sv"
TB="$ROOT/tests/rtl/h264_deblock_mb_sched_tb.cpp"
BUILD="$ROOT/build/verilator/deblock_sched"

for f in "$RTL_SCHED" "$RTL_DEBLOCK" "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_deblock_scheduler.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_deblock_scheduler.sv" >&2
  exit 2
fi

mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_deblock_mb_sched_tb -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL_SCHED" "$RTL_DEBLOCK" "$TB"
"$BUILD/Vh264_deblock_mb_sched_tb"

# Run the Python reference model self-test
python3 "$ROOT/tests/models/h264_deblock_ref.py" --self-test

echo "OK h264_deblock_scheduler RTL sim + reference model: all tests passed"
