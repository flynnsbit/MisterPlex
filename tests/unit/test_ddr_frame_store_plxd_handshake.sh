#!/usr/bin/env bash
# RTL-half PLXD/doorbell handshake under sustained back-to-back rings.
# A) sticky=0 → REPRO free_mask=00 + frames_done stall
# B) product sticky+recycle → PASS PLXD live/advancing, free honest
# Asserts TB EXECUTED. PINNOTFOUND/%Error → rc=2 via run_verilator.
set -euo pipefail

assert_sim_executed() {
  local label="$1"; shift
  local log="$1"; shift
  local missing=0
  local m
  for m in "$@"; do
    if ! grep -q -- "$m" <<<"$log"; then
      echo "FAIL $label: sim did not EXECUTE expected marker: $m" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "FAIL $label: compile-only or empty run is not a pass" >&2
    exit 2
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
INC="-I$RTL"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BROKEN_BUILD="$ROOT/build/verilator/ddr_plxd_handshake_broken"
GOOD_BUILD="$ROOT/build/verilator/ddr_plxd_handshake_good"
mkdir -p "$BROKEN_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_plxd_handshake_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_base_mux.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_plxd_handshake_tb.cpp"
)
vflags=($INC --cc --exe --build --top-module ddr_frame_store_plxd_handshake_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) BROKEN sticky=0 recycle=0 (expect REPRO handshake stall) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BROKEN_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=0 -GPREP_SLOT_RECYCLE=0 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1 \
  "${common_sv[@]}"
set +e
BROKEN_OUT="$("$BROKEN_BUILD/Vddr_frame_store_plxd_handshake_tb" 2>&1)"
BROKEN_RC=$?
set -e
printf '%s\n' "$BROKEN_OUT"
echo "broken rc=$BROKEN_RC"

echo "=== B) GOOD sticky=1 recycle=1 (expect PASS PLXD advancing) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  -GWANT_Y_LINE_ONLY=1 -GPENDING_READY_STICKY_PREP=1 -GPREP_SLOT_RECYCLE=1 \
  -GSWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC=1 \
  "${common_sv[@]}"
set +e
GOOD_OUT="$("$GOOD_BUILD/Vddr_frame_store_plxd_handshake_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "good rc=$GOOD_RC"

assert_sim_executed "plxd-broken" "$BROKEN_OUT" \
  "PASS protocol model" "REPRO_OK" "plxd_nosticky" "free_mask=00"
assert_sim_executed "plxd-good" "$GOOD_OUT" \
  "PASS protocol model" "PASS plxd_product" "PLXD live"

if [[ "$BROKEN_RC" -ne 0 ]] || ! grep -q 'REPRO_OK plxd_nosticky' <<<"$BROKEN_OUT"; then
  echo "FAIL: sticky=0 did not REPRO PLXD handshake stall" >&2
  exit 1
fi
if [[ "$GOOD_RC" -ne 0 ]] || ! grep -q 'PASS plxd_product' <<<"$GOOD_OUT"; then
  echo "FAIL: product did not keep PLXD advancing under back-to-back rings" >&2
  exit 1
fi
echo "OK ddr_frame_store_plxd_handshake: REPRO_OK nosticky + PASS product (TB executed)"
exit 0
