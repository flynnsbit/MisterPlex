#!/usr/bin/env bash
# B20 bank+geometry atomicity: product holds app pitch until bank swap;
# FAULT free-run REPRO moves app with PLXG promote.
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

FAULT_BUILD="$ROOT/build/verilator/ddr_b20_fault"
GOOD_BUILD="$ROOT/build/verilator/ddr_b20_good"
# Force rebuild — source edits must not hit stale "Nothing to be done".
rm -rf "$FAULT_BUILD" "$GOOD_BUILD"
mkdir -p "$FAULT_BUILD" "$GOOD_BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2

common_sv=(
  "$ROOT/tests/rtl/ddr_frame_store_b20_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_store.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_geom_lock.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/line_buf_ram.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
  "$ROOT/tests/rtl/ddr_frame_store_b20_tb.cpp"
)
vflags=(--cc --exe --build --top-module ddr_frame_store_b20_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -CFLAGS "-std=c++17 -O2")

echo "=== A) FAULT_B20_FREE_RUN_GEOM (expect REPRO_OK) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$FAULT_BUILD" \
  -DDDR_FRAME_STORE_FAULT_B20_FREE_RUN_GEOM \
  "${common_sv[@]}"
set +e
FAULT_OUT="$(B20_MODE=fault "$FAULT_BUILD/Vddr_frame_store_b20_tb" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
echo "fault true rc=$FAULT_RC"
assert_sim_executed "b20-fault" "$FAULT_OUT" "REPRO_OK" "MEASURED FAULT"
if [[ "$FAULT_RC" -ne 0 ]]; then
  echo "FAIL b20 fault twin rc=$FAULT_RC (REPRO must exit 0)" >&2
  exit 2
fi

echo "=== B) PRODUCT B20 atomic (expect OK holds until swap) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$GOOD_BUILD" \
  "${common_sv[@]}"
set +e
GOOD_OUT="$(B20_MODE=product "$GOOD_BUILD/Vddr_frame_store_b20_tb" 2>&1)"
GOOD_RC=$?
set -e
printf '%s\n' "$GOOD_OUT"
echo "product true rc=$GOOD_RC"
assert_sim_executed "b20-product" "$GOOD_OUT" \
  "OK delayed-promotion" "OK B20 product" "OK B20 mode-exit" \
  "OK B20 mode-exit pixel oracle" "OK B20 dar_hold content RGB black" \
  "OK B20 beam lock holds OLD DE until pending_ready swap" \
  "OK B20 visual hold black until swap ack" \
  "MEASURED after_promote" "MEASURED after_swap" "MEASURED mode_exit" \
  "MEASURED mode_exit_scan" "MEASURED dar_hold_rgb" "MEASURED beam_delay"
if [[ "$GOOD_RC" -ne 0 ]]; then
  echo "FAIL b20 product rc=$GOOD_RC" >&2
  exit "$GOOD_RC"
fi

# --- C) FAULT SPI ungated: SPI swaps before promote (REPRO corruption class) ---
SPI_BUILD="$ROOT/build/verilator/ddr_b20_spi_fault"
rm -rf "$SPI_BUILD"
mkdir -p "$SPI_BUILD"
echo "=== C) FAULT_SPI_UNGATED delayed-promo SPI (expect swap REPRO) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$SPI_BUILD" \
  -DDDR_FRAME_STORE_FAULT_SPI_UNGATED \
  -CFLAGS "-std=c++17 -O2 -DB20_SPI_FAULT_TWIN=1" \
  "${common_sv[@]}"
set +e
SPI_OUT="$(B20_MODE=spi_fault "$SPI_BUILD/Vddr_frame_store_b20_tb" 2>&1)"
SPI_RC=$?
set -e
printf '%s\n' "$SPI_OUT"
echo "spi_fault true rc=$SPI_RC"
assert_sim_executed "b20-spi-fault" "$SPI_OUT" "REPRO spi-before-promote"
if [[ "$SPI_RC" -ne 2 ]]; then
  echo "FAIL b20 spi fault twin expected rc=2 got $SPI_RC" >&2
  exit 2
fi

# --- D) FAULT ascal-only DAR: content RGB stays lit under dar_hold (REPRO) ---
DAR_BUILD="$ROOT/build/verilator/ddr_b20_dar_fault"
rm -rf "$DAR_BUILD"
mkdir -p "$DAR_BUILD"
echo "=== D) FAULT_DAR_BLACK_ASCAL_ONLY (expect held maxRGB!=0) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$DAR_BUILD" \
  -DDDR_FRAME_STORE_FAULT_DAR_BLACK_ASCAL_ONLY \
  "${common_sv[@]}"
set +e
DAR_OUT="$(B20_MODE=product "$DAR_BUILD/Vddr_frame_store_b20_tb" 2>&1)"
DAR_RC=$?
set -e
printf '%s\n' "$DAR_OUT" | tail -25
echo "dar_fault true rc=$DAR_RC"
if [[ "$DAR_RC" -eq 0 ]]; then
  echo "FAIL FAULT twin should not pass product dar RGB check" >&2
  exit 1
fi
if ! grep -q "FAIL product: dar_hold_black must force content RGB=0" <<<"$DAR_OUT"; then
  echo "FAIL expected dar content-RGB REPRO marker" >&2
  printf '%s\n' "$DAR_OUT" >&2
  exit 1
fi
echo "REPRO_OK FAULT_DAR_BLACK_ASCAL_ONLY held RGB non-zero"

# --- E) FAULT_B20_BEAM_FREE_RUN: locked follows live NEW while app OLD ---
BEAM_BUILD="$ROOT/build/verilator/ddr_b20_beam_fault"
rm -rf "$BEAM_BUILD"
mkdir -p "$BEAM_BUILD"
echo "=== E) FAULT_B20_BEAM_FREE_RUN (expect locked=NEW while app OLD) ===" >&2
"$RUN_VERILATOR" "${vflags[@]}" --Mdir "$BEAM_BUILD" \
  -DFAULT_B20_BEAM_FREE_RUN \
  "${common_sv[@]}"
set +e
BEAM_OUT="$(B20_MODE=product "$BEAM_BUILD/Vddr_frame_store_b20_tb" 2>&1)"
BEAM_RC=$?
set -e
printf '%s\n' "$BEAM_OUT" | tail -30
echo "beam_fault true rc=$BEAM_RC"
if [[ "$BEAM_RC" -eq 0 ]]; then
  echo "FAIL FAULT beam free-run twin should fail product beam lock" >&2
  exit 1
fi
if ! grep -q "FAIL beam-hier: locked beam NEW while store OLD" <<<"$BEAM_OUT"; then
  echo "FAIL expected beam free-run REPRO marker" >&2
  printf '%s\n' "$BEAM_OUT" >&2
  exit 1
fi
echo "REPRO_OK FAULT_B20_BEAM_FREE_RUN locked NEW / app OLD"

echo "OK test_ddr_frame_store_b20"
exit 0
