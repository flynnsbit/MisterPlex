#!/usr/bin/env bash
# Execute serialized MC interpolator RTL (luma qpel + chroma epel) under Verilator.
# A missing Verilator is NOT a pass.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_LUMA="$ROOT/fpga/Plex_MiSTer/rtl/h264_mc_luma_qpel.sv"
RTL_CHROMA="$ROOT/fpga/Plex_MiSTer/rtl/h264_mc_chroma_epel.sv"
TOP="$ROOT/tests/rtl/h264_mc_qpel_tb_top.sv"
TB="$ROOT/tests/rtl/h264_mc_qpel_tb.cpp"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
BUILD_DIR="$ROOT/build/verilator/h264_mc_qpel"
LOG="$ROOT/build/h264_mc_qpel_verilator.log"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_mc_qpel real RTL simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite-20260726 or set VERILATOR=/path/to/verilator.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    echo "A skipped RTL gate is NOT a pass. Set ALLOW_MISSING_VERILATOR=1 only if you accept that RTL was never verified." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

for f in "$RTL_LUMA" "$RTL_CHROMA" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing $f" >&2
    exit 2
  fi
done

mkdir -p "$BUILD_DIR" "$(dirname "$LOG")"
echo "RTL SIM: using $VERILATOR_VERSION (h264_mc_qpel)" >&2
OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_DIR" \
  --top-module h264_mc_qpel_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL_LUMA" "$RTL_CHROMA" "$TOP" "$TB"

EXE="$BUILD_DIR/Vh264_mc_qpel_tb_top"
set +e
"$EXE" >"$LOG" 2>&1
RC=$?
set -e
cat "$LOG" >&2
if [[ "$RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: h264_mc_qpel failed rc=$RC" >&2
  exit "$RC"
fi
if ! grep -q "MC RTL SIM PASS" "$LOG"; then
  echo "RTL SIM ERROR: PASS marker missing from log" >&2
  exit 1
fi
echo "RTL SIM OK: h264_mc_qpel (see $LOG)" >&2
exit 0
