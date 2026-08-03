#!/usr/bin/env bash
# CEA raster + phase sweep; real rate_match; H_TOTAL slots + HS width.
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
  "$ROOT/fpga/Plex_MiSTer/rtl/present_pix_rate_match.sv"
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
  "$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_cea_raster_tb \
    "$@" -Mdir "$OUT/$name" "${SRCS[@]}" >/dev/null
  set +e
  "$OUT/$name/Vpresent_npx_cea_raster_tb" >"$OUT/$name.log" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    tail -40 "$OUT/$name.log"
    echo "FAIL $name nonzero rc=$rc (marker alone is not enough)" >&2
    exit 1
  fi
  grep -q "$pass_pat" "$OUT/$name.log" || {
    tail -40 "$OUT/$name.log"
    echo "FAIL $name missing '$pass_pat' rc=$rc" >&2
    exit 1
  }
  echo "OK $name rc=$rc"
}

HT=1650
HDE=1280
if [[ "${FULL:-0}" == "1" ]]; then
  VA=720; VT=750; VSS=725; VSE=730
else
  VA=8; VT=12; VSS=9; VSE=11
fi

GCOMMON=(-GH_DE=$HDE -GH_TOTAL=$HT -GV_ACTIVE=$VA -GV_TOTAL=$VT \
  -GV_SYNC_S=$VSS -GV_SYNC_E=$VSE -GPREFILL=8 -GPX_PER_CLK=2 -GNUM_FRAMES=2)

run_one green_cea "PASS present_npx_cea act=" "${GCOMMON[@]}" -GPHASE_PS=0 -GACC_SEED=0
run_one red_cea "PASS present_npx_cea RED" "${GCOMMON[@]}" -GRED_STARVE=1

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
