#!/usr/bin/env bash
# Analog raster mux: 240p 15.6 kHz vs 480p 31 kHz vs 480i field.
# v1 reset-latch: live raster_sel / live PLXH doorbell must not retarget H until reset.
# RED twins: SWAP_SEL, LIVE_LATCH (fstart reload), LIVE_DOORBELL (live hop). Soft-skip ≠ PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
RTL_MUX="$ROOT/fpga/Plex_MiSTer/rtl/analog_raster_mux.sv"
RTL_BARS="$ROOT/fpga/Plex_MiSTer/rtl/colorbars.sv"
TB="$ROOT/tests/rtl/analog_raster_mux_tb.cpp"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
  exit 3
elif [[ "$VERILATOR_RC" -eq 77 ]]; then
  echo "RTL SIM ERROR: Verilator probe rc=77 is skip, not PASS." >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BUILD="$ROOT/build/verilator/analog_raster_mux"
FAULT_BUILD="$ROOT/build/verilator/analog_raster_mux_fault"
LIVE_BUILD="$ROOT/build/verilator/analog_raster_mux_live_latch"
LIVE_DB_BUILD="$ROOT/build/verilator/analog_raster_mux_live_doorbell"
mkdir -p "$BUILD" "$FAULT_BUILD" "$LIVE_BUILD" "$LIVE_DB_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  "$RTL_MUX" "$RTL_BARS" "$TB"
set +e
GREEN_OUT="$("$BUILD/Vanalog_raster_mux" 2>&1)"
GREEN_RC=$?
set -e
printf '%s\n' "$GREEN_OUT"
echo "true rc=$GREEN_RC GREEN analog_raster_mux"
if [[ "$GREEN_RC" -eq 77 ]]; then
  echo "FAIL analog_raster_mux green: rc=77 is skip not PASS" >&2
  exit 1
fi
if [[ "$GREEN_RC" -ne 0 ]]; then
  echo "FAIL analog_raster_mux green" >&2
  exit "$GREEN_RC"
fi
if ! grep -q 'reset-latch after live sel=1' <<<"$GREEN_OUT"; then
  echo "FAIL analog_raster_mux green: missing reset-latch diagnostic" >&2
  exit 1
fi
if ! grep -q 'doorbell-hold after live db=1' <<<"$GREEN_OUT"; then
  echo "FAIL analog_raster_mux green: missing doorbell-hold diagnostic" >&2
  exit 1
fi
if ! grep -q 'OK analog_raster_mux' <<<"$GREEN_OUT"; then
  echo "FAIL analog_raster_mux green: missing OK line" >&2
  exit 1
fi

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$FAULT_BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  +define+ANALOG_RASTER_FAULT_SWAP_SEL \
  "$RTL_MUX" "$RTL_BARS" "$TB"
set +e
FAULT_OUT="$("$FAULT_BUILD/Vanalog_raster_mux" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "true rc=$FAULT_RC RED ANALOG_RASTER_FAULT_SWAP_SEL"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL analog_raster_mux red-check: swapped-sel fault unexpectedly passed" >&2
  exit 1
fi
if [[ "$FAULT_RC" -eq 77 ]]; then
  echo "FAIL analog_raster_mux red-check: swapped-sel rc=77 is skip not FAIL" >&2
  exit 1
fi
if ! grep -q 'FAIL 240p' <<<"$FAULT_OUT"; then
  echo "FAIL analog_raster_mux red-check: expected 240p class diagnostic" >&2
  exit 1
fi
echo "OK analog_raster_mux red-check: swapped sel failed 15.6 vs 31 kHz class"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$LIVE_BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  +define+ANALOG_RASTER_FAULT_LIVE_LATCH \
  "$RTL_MUX" "$RTL_BARS" "$TB"
set +e
LIVE_OUT="$("$LIVE_BUILD/Vanalog_raster_mux" 2>&1)"
LIVE_RC=$?
set -e
printf '%s\n' "$LIVE_OUT"
echo "true rc=$LIVE_RC RED ANALOG_RASTER_FAULT_LIVE_LATCH"
if [[ "$LIVE_RC" -eq 0 ]]; then
  echo "FAIL analog_raster_mux red-check: live-latch fault unexpectedly passed" >&2
  exit 1
fi
if [[ "$LIVE_RC" -eq 77 ]]; then
  echo "FAIL analog_raster_mux red-check: live-latch rc=77 is skip not FAIL" >&2
  exit 1
fi
if ! grep -q 'FAIL reset-latch' <<<"$LIVE_OUT"; then
  echo "FAIL analog_raster_mux red-check: expected reset-latch diagnostic" >&2
  exit 1
fi
echo "OK analog_raster_mux red-check: live fstart latch failed reset-hold"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$LIVE_DB_BUILD" \
  --top-module analog_raster_mux -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  +define+ANALOG_RASTER_FAULT_LIVE_DOORBELL \
  "$RTL_MUX" "$RTL_BARS" "$TB"
set +e
LIVE_DB_OUT="$("$LIVE_DB_BUILD/Vanalog_raster_mux" 2>&1)"
LIVE_DB_RC=$?
set -e
printf '%s\n' "$LIVE_DB_OUT"
echo "true rc=$LIVE_DB_RC RED ANALOG_RASTER_FAULT_LIVE_DOORBELL"
if [[ "$LIVE_DB_RC" -eq 0 ]]; then
  echo "FAIL analog_raster_mux red-check: live-doorbell fault unexpectedly passed" >&2
  exit 1
fi
if [[ "$LIVE_DB_RC" -eq 77 ]]; then
  echo "FAIL analog_raster_mux red-check: live-doorbell rc=77 is skip not FAIL" >&2
  exit 1
fi
if ! grep -q 'FAIL doorbell-hold' <<<"$LIVE_DB_OUT"; then
  echo "FAIL analog_raster_mux red-check: expected doorbell-hold diagnostic" >&2
  exit 1
fi
echo "OK analog_raster_mux red-check: live doorbell hop failed reset-hold"
echo "true rc=$GREEN_RC GREEN; true rc=$FAULT_RC SWAP_SEL; true rc=$LIVE_RC LIVE_LATCH; true rc=$LIVE_DB_RC LIVE_DOORBELL"
