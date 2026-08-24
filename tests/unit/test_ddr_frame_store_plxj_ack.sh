#!/usr/bin/env bash
# PLXJ ACK: ioctl index 4 PLXA → toggle → WE 0x3007F130 (not L4 0x3047F130).
# GREEN: analog-DE rd_active=1, has_frame=0 still ACKs (gold 5f1c8614 250 ms).
# RED: SOURCE_ASPECT_ACK_FAULT_IGNORE_INDEX_MAGIC ACKs index!=4 / non-PLXA.
# Soft-skip ≠ PASS. Quote true rc=.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
BUILD="$ROOT/build/verilator/ddr_plxj_ack"
FAULT_BUILD="$ROOT/build/verilator/ddr_plxj_ack_fault"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
TB="$ROOT/tests/rtl"
mkdir -p "$BUILD" "$FAULT_BUILD"

STORE="$RTL/ddr_frame_store.sv"
ACK="$RTL/source_aspect_ack.sv"
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
QSF="$ROOT/fpga/Plex_MiSTer/Plex.qsf"

grep -q 'parameter \[31:0\] ASPECT_ACK_PHYS    = 32.h3007_F130' "$STORE" \
  || { echo "FAIL product ASPECT_ACK_PHYS is not 0x3007F130" >&2; exit 1; }
grep -q "assign VGA_SCALER  = 0;" "$PLEX" \
  || { echo "FAIL VGA_SCALER must stay 0" >&2; exit 1; }
grep -q '#set_global_assignment -name VERILOG_MACRO "PLEX_PRESENT_720P_L4=1"' "$QSF" \
  || { echo "FAIL L4 must stay commented off in Plex.qsf" >&2; exit 1; }
# PLXJ must be the first S_IDLE arm (fills starved compose ae26f31e).
# mux7: take on plxj_req (not we_go). Park every other S_IDLE arm while req.
# S_PLXJ_ISSUE keeps registered WE (mux5/6 hold cut).
awk '
  /case \(state_ddr\)/ {in_case=1}
  in_case && /S_IDLE: begin/ {in_idle=1}
  in_idle && /if \(plxj_req && !DDRAM_BUSY && !DDRAM_WE\)/ {print "PLXJ_FIRST"; exit 0}
  in_idle && /frame_mbox_req/ {print "MBOX_BEFORE_PLXJ"; exit 1}
' "$STORE" | grep -q PLXJ_FIRST \
  || { echo "FAIL PLXJ ACK is not first S_IDLE arm (fills will starve analog Template)" >&2; exit 1; }
grep -q 'else if (plxj_req) begin' "$STORE" \
  || { echo "FAIL S_IDLE must park all other arms while plxj_req" >&2; exit 1; }
grep -q 'plxj_acked <= 1'\''b1' "$STORE" \
  || { echo "FAIL first PLXJ take must set plxj_acked" >&2; exit 1; }
grep -q 'plxj_acked && !poll_pending' "$STORE" \
  || { echo "FAIL doorbell/PLXH poll must wait for first ACK (mux7 hung S_POLL_WAIT)" >&2; exit 1; }
grep -q 'else if (!plxj_acked) begin' "$STORE" \
  || { echo "FAIL S_IDLE must skip mbox/fill until first ACK (mux8 mbox steal)" >&2; exit 1; }
grep -q 'ASPECT_ACK2_PHYS   = 32.h300F_F130' "$STORE" \
  || { echo "FAIL must mirror PLXJ to 0x300FF130 (gold daemon doorbell+0x130)" >&2; exit 1; }
grep -q 'localparam \[3:0\] S_PLXJ_ISSUE = 4.d6' "$STORE" \
  || { echo "FAIL S_PLXJ_ISSUE extra WE stage missing (mux5 hold cut)" >&2; exit 1; }
if grep -q 'plxj_we_go && plxj_req' "$STORE"; then
  echo "FAIL mux6 we_go AND must not gate S_IDLE take (glass ACK after 250 ms)" >&2
  exit 1
fi
if grep -nE '^[[:space:]]*set_clock_groups[[:space:]]+-asynchronous' \
     "$ROOT/fpga/Plex_MiSTer/Plex.sdc" "$ROOT/fpga/Plex_MiSTer/Plex_analog_mux.sdc"; then
  echo "FAIL do not hide clk_ddr hold with new -asynchronous clock groups" >&2
  exit 1
fi
grep -q 'ioctl_index\[5:0\] == 6.d4' "$ACK" \
  || { echo "FAIL source_aspect_ack must require ioctl_index[5:0]==4" >&2; exit 1; }

set +e
VOUT="$($RUN --version 2>&1)"
VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
  exit 3
elif [[ "$VRC" -eq 77 ]]; then
  echo "RTL SIM ERROR: Verilator probe rc=77 is skip, not PASS." >&2
  exit 3
elif [[ "$VRC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VOUT" >&2
  exit 3
fi
echo "RTL SIM: using $VOUT" >&2

"$RUN" -sv -cc --exe --build -Mdir "$BUILD" \
  -CFLAGS "-std=c++17 -O2" \
  -Wno-WIDTH -Wno-SELRANGE -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-fatal \
  -I"$RTL" --top-module ddr_frame_store_plxj_ack_tb \
  "$TB/ddr_frame_store_plxj_ack_tb_top.sv" \
  "$RTL/ddr_frame_store.sv" \
  "$RTL/source_aspect_ack.sv" \
  "$RTL/async_fifo.sv" \
  "$RTL/line_buf_ram.sv" \
  "$RTL/ddr_frame_base_mux.sv" \
  "$TB/ddr_frame_store_plxj_ack_tb.cpp" -o Vddr_frame_store_plxj_ack_tb
set +e
GREEN_OUT="$("$BUILD/Vddr_frame_store_plxj_ack_tb" 2>&1)"
GREEN_RC=$?
set -e
printf '%s\n' "$GREEN_OUT"
echo "true rc=$GREEN_RC GREEN ddr_frame_store_plxj_ack"
if [[ "$GREEN_RC" -eq 77 ]]; then
  echo "FAIL plxj ack green: rc=77 is skip not PASS" >&2
  exit 1
fi
if [[ "$GREEN_RC" -ne 0 ]]; then
  echo "FAIL plxj ack green" >&2
  exit "$GREEN_RC"
fi
if ! grep -q 'OK plxj ack: toggle then WE 0x3007F130' <<<"$GREEN_OUT"; then
  echo "FAIL plxj ack green: missing OK WE line" >&2
  exit 1
fi

"$RUN" -sv -cc --exe --build -Mdir "$FAULT_BUILD" \
  -CFLAGS "-std=c++17 -O2" \
  -Wno-WIDTH -Wno-SELRANGE -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-fatal \
  -I"$RTL" --top-module ddr_frame_store_plxj_ack_tb \
  +define+SOURCE_ASPECT_ACK_FAULT_IGNORE_INDEX_MAGIC \
  "$TB/ddr_frame_store_plxj_ack_tb_top.sv" \
  "$RTL/ddr_frame_store.sv" \
  "$RTL/source_aspect_ack.sv" \
  "$RTL/async_fifo.sv" \
  "$RTL/line_buf_ram.sv" \
  "$RTL/ddr_frame_base_mux.sv" \
  "$TB/ddr_frame_store_plxj_ack_tb.cpp" -o Vddr_frame_store_plxj_ack_tb
set +e
FAULT_OUT="$("$FAULT_BUILD/Vddr_frame_store_plxj_ack_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "true rc=$FAULT_RC RED SOURCE_ASPECT_ACK_FAULT_IGNORE_INDEX_MAGIC"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL plxj ack red-check: ignore-index-magic fault unexpectedly passed" >&2
  exit 1
fi
if [[ "$FAULT_RC" -eq 77 ]]; then
  echo "FAIL plxj ack red-check: rc=77 is skip not FAIL" >&2
  exit 1
fi
if ! grep -q 'FAIL index 5 ioctl produced PLXJ WE' <<<"$FAULT_OUT"; then
  echo "FAIL plxj ack red-check: expected index-5 WE diagnostic" >&2
  exit 1
fi
echo "OK plxj ack red-check: wrong index/magic ACK is load-bearing"
echo "true rc=$GREEN_RC GREEN; true rc=$FAULT_RC RED IGNORE_INDEX_MAGIC"
