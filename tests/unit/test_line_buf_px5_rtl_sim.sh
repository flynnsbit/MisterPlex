#!/usr/bin/env bash
# Verilator: packed 256×40 line buffer pack → RAM → stream_rd (+ unpack).
# NEGATIVE: naive first-5-of-8 packer must not match RTL.
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
MDIR="$ROOT/build/verilator/line_buf_px5"
RTL_DIR="$ROOT/fpga/Plex_MiSTer/rtl"
TOP="$ROOT/tests/rtl/line_buf_px5_tb_top.sv"
TB="$ROOT/tests/rtl/line_buf_px5_tb.cpp"
mkdir -p "$MDIR"

echo "=== test_line_buf_px5_rtl_sim EXECUTED ==="

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]]; then
    echo "SKIP-NOT-PASS RTL SIM: Verilator not found" >&2
    exit 77
  fi
  echo "RTL SIM ERROR: Verilator not found" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

for f in line_buf_px5_pack.sv line_buf_ram_px5.sv line_buf_px5_stream_rd.sv line_buf_px5_unpack.sv; do
  test -f "$RTL_DIR/$f" || { echo "FAIL missing $RTL_DIR/$f" >&2; exit 2; }
done

set +e
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$MDIR" \
  --top-module line_buf_px5_tb_top \
  -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" \
  "$RTL_DIR/line_buf_px5_pack.sv" \
  "$RTL_DIR/line_buf_ram_px5.sv" \
  "$RTL_DIR/line_buf_px5_stream_rd.sv" \
  "$RTL_DIR/line_buf_px5_unpack.sv" \
  "$TB"
v_rc=$?
set -e
echo "verilator_build true rc=$v_rc"
if [[ "$v_rc" -ne 0 ]]; then
  echo "FAIL verilator build" >&2
  exit "$v_rc"
fi

BIN="$MDIR/Vline_buf_px5_tb_top"
test -x "$BIN" || BIN="$MDIR/Vline_buf_px5_tb_top.exe"
set +e
out=$("$BIN" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"
echo "sim true rc=$rc"

assert_sim_executed "line_buf_px5" "$out" \
  "CASE EXECUTED" \
  "OK A pack_1280_continuous_beats" \
  "OK B stream_rd_1280" \
  "OK C NEGATIVE naive_first5of8_rejected" \
  "OK D unpack_phases_0_4" \
  "OK E stream_ppc2_straddle" \
  "OK F NEGATIVE single_word_phase4" \
  "OK G line_boundary" \
  "OK H NEGATIVE_scaler_jump_unsupported" \
  "SUMMARY PASS"

if [[ "$rc" -ne 0 ]]; then
  echo "FAIL sim rc=$rc" >&2
  exit "$rc"
fi
echo "test_line_buf_px5_rtl_sim: OK"
exit 0
