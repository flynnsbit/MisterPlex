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
SKIP RTL SIM: Verilator not found; ddram_frame_rd bank-select simulation was NOT run.
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

BUILD="$ROOT/build/verilator/ddram_frame_rd_bank"
FRAME_W=624
FRAME_H=480
FRAME_BYTES=$((FRAME_W * FRAME_H * 3 / 2))
STRIDE_ALIGN=$((0x40000))
BANK_STRIDE=$((((FRAME_BYTES + STRIDE_ALIGN - 1) / STRIDE_ALIGN) * STRIDE_ALIGN))
DOORBELL_PHYS=$((0x30000000 + BANK_STRIDE * 2 - 0x1000))
mkdir -p "$BUILD"
"$RUN_VERILATOR" -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" -I"$ROOT/host" \
  --cc --exe --build \
  --top-module ddram_frame_rd \
  -GWIDTH="$FRAME_W" -GHEIGHT="$FRAME_H" -GDOORBELL_PHYS="$DOORBELL_PHYS" \
  --Mdir "$BUILD" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddram_frame_rd.sv" \
  "$ROOT/tests/rtl/ddram_frame_rd_bank_tb.cpp"
"$BUILD/Vddram_frame_rd"
