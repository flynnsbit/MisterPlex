#!/usr/bin/env bash
# Verilator: refresh measure PASS@24 FAIL@16.16 (negative trap)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/build/verilator/plex_clk_refresh_meas"
mkdir -p "$BUILD"
export PATH="${HOME}/.local/oss-cad-suite/bin:${PATH}"

echo "=== test_plex_clk_refresh_meas_verilator EXECUTED ==="

VERILATOR=(verilator --cc --exe --build -sv -O2
  -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD
  -CFLAGS "-std=c++17 -O2"
  -DTB_MEAS_WIN=20000
  -DPRESENT_CLK_PIX_PLL=1
  -I"$ROOT/fpga/Plex_MiSTer/rtl"
  --top-module plex_clk_refresh_meas_tb_top
  -Mdir "$BUILD"
  "$ROOT/tests/rtl/plex_clk_refresh_meas_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_clk_status.sv"
  "$ROOT/tests/rtl/plex_clk_refresh_meas_tb.cpp"
)

set +e
"${VERILATOR[@]}"
BRC=$?
set -e
echo "verilator_build true rc=$BRC"
if [[ $BRC -ne 0 ]]; then exit $BRC; fi
BIN="$BUILD/Vplex_clk_refresh_meas_tb_top"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: binary missing"
  exit 1
fi
set +e
OUT=$("$BIN" 2>&1)
TRC=$?
set -e
printf '%s\n' "$OUT"
echo "tb true rc=$TRC"
# Proof-of-execution (false-green guard): require PASS markers from both cases
if ! printf '%s\n' "$OUT" | grep -q "PASS POS_24HZ"; then
  echo "FAIL: missing PASS POS_24HZ"
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -q "PASS NEG_16HZ_TRAP"; then
  echo "FAIL: missing PASS NEG_16HZ_TRAP (negative case must run)"
  exit 1
fi
if ! printf '%s\n' "$OUT" | grep -q "PASS plex_clk_refresh_meas_tb all cases"; then
  echo "FAIL: missing all-cases PASS"
  exit 1
fi
if [[ $TRC -ne 0 ]]; then exit $TRC; fi
echo "PASS test_plex_clk_refresh_meas_verilator"
exit 0
