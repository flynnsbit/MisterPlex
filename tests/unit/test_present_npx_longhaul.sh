#!/usr/bin/env bash
# Long-haul npx: producer lead + prefill vs ±pix ppm and phase.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -x "$ROOT/scripts/run_verilator.sh" ]]; then RV="$ROOT/scripts/run_verilator.sh"
elif command -v verilator >/dev/null 2>&1; then RV="$(command -v verilator)"
else echo "SKIP-NOT-PASS: Verilator missing" >&2; exit 77; fi
OUT="$ROOT/build/verilator/present_npx_longhaul"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_npx_longhaul_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)
echo "RTL SIM: $($RV --version 2>&1 | head -1)"
run_one() {
  local name="$1"; shift
  rm -rf "$OUT/$name"
  "$RV" -Wno-fatal --binary --timing --top-module present_npx_longhaul_tb \
    "$@" -Mdir "$OUT/$name" "${SRCS[@]}" >/dev/null
  set +e
  "$OUT/$name/Vpresent_npx_longhaul_tb" >"$OUT/$name.log" 2>&1
  local rc=$?
  set -e
  grep -q "PASS present_npx_longhaul" "$OUT/$name.log" || {
    tail -40 "$OUT/$name.log"; echo "FAIL $name"; exit 1; }
  echo "OK $name rc=$rc"
}
# nominal + drift + phases
run_one nom0 -GPPM_OFF=0 -GPHASE_PS=0
run_one p1000 -GPPM_OFF=1000 -GPHASE_PS=0
run_one m1000 -GPPM_OFF=-1000 -GPHASE_PS=0
run_one ph18 -GPPM_OFF=0 -GPHASE_PS=18
run_one p1000_ph16 -GPPM_OFF=1000 -GPHASE_PS=16
run_one m1000_ph34 -GPPM_OFF=-1000 -GPHASE_PS=34
echo "PASS test_present_npx_longhaul"
exit 0
