#!/usr/bin/env bash
# CEA raster + phase/seed sweep for wide-group present_npx_path (+prefill).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -x "$ROOT/scripts/run_verilator.sh" ]]; then
  RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
elif command -v verilator >/dev/null 2>&1; then
  RUN_VERILATOR="$(command -v verilator)"
else
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
fi

OUT="$ROOT/build/verilator/present_npx_cea_raster"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_npx_cea_raster_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)

echo "RTL SIM: $($RUN_VERILATOR --version 2>&1 | head -1)"

run_one() {
  local name="$1"
  shift
  local pass_pat="$1"
  shift
  rm -rf "$OUT/$name"
  # remaining args are -G flags
  "$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_cea_raster_tb \
    "$@" -Mdir "$OUT/$name" "${SRCS[@]}" >/dev/null
  set +e
  "$OUT/$name/Vpresent_npx_cea_raster_tb" >"$OUT/$name.log" 2>&1
  local rc=$?
  set -e
  grep -q "$pass_pat" "$OUT/$name.log" || {
    tail -40 "$OUT/$name.log"
    echo "FAIL $name missing '$pass_pat' rc=$rc" >&2
    exit 1
  }
  echo "OK $name rc=$rc"
}

# Fast geometry: full CEA line width, few lines — proves blanking HS + prefill
# under Bresenham. Full 750-line frame is optional slow path (FULL=1).
HT=1650
HDE=1280
if [[ "${FULL:-0}" == "1" ]]; then
  VA=720; VT=750; VSS=725; VSE=730
else
  # Short frame: keep HS geometry; place VS inside VT
  VA=8; VT=12; VSS=9; VSE=11
fi

GCOMMON=(-GH_DE=$HDE -GH_TOTAL=$HT -GV_ACTIVE=$VA -GV_TOTAL=$VT   -GV_SYNC_S=$VSS -GV_SYNC_E=$VSE -GPREFILL=8 -GPX_PER_CLK=2)

run_one green_cea "PASS present_npx_cea act=" "${GCOMMON[@]}" -GPHASE_PS=0 -GACC_SEED=0
run_one red_cea "PASS present_npx_cea RED" "${GCOMMON[@]}" -GRED_STARVE=1

# Phase + accumulator seed sweep (rd-duck: 0..16ns risk window + outside).
# Default = representative grid. EXTENDED=1 for dense grid.
if [[ "${EXTENDED:-0}" == "1" ]]; then
  PHASES=(0 5 10 15 18 20 25 30 34)
  SEEDS=(0 100 200 300)
else
  PHASES=(0 10 16 18 34)
  SEEDS=(0 200)
fi
for ph in "${PHASES[@]}"; do
  for seed in "${SEEDS[@]}"; do
    run_one "ph${ph}_s${seed}" "PASS present_npx_cea act=" \
      "${GCOMMON[@]}" -GPHASE_PS=$ph -GACC_SEED=$seed
  done
done

echo "PASS test_present_npx_cea_raster"
exit 0
