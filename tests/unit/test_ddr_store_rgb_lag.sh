#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
RV=scripts/run_verilator.sh
base=(--cc --exe --build --top-module ddr_store_rgb_lag_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  -Ifpga/Plex_MiSTer/rtl
  tests/rtl/ddr_store_rgb_lag_tb_top.sv
  fpga/Plex_MiSTer/rtl/ddr_frame_store.sv
  fpga/Plex_MiSTer/rtl/ddr_bank_stride_guard.sv
  fpga/Plex_MiSTer/rtl/line_buf_ram.sv
  fpga/Plex_MiSTer/rtl/async_fifo.sv
  tests/rtl/ddr_store_rgb_lag_tb.cpp)

run_one() {
  local w="$1" dir="$2"
  local phys stride db
  if [[ "$w" -ge 960 ]]; then
    phys=32\'h30180000; stride=32\'h00180000; db=32\'h3047F000
  else
    phys=32\'h30000000; stride=32\'h00080000; db=32\'h300FF000
  fi
  mkdir -p "$dir"
  "$RV" "${base[@]}" --Mdir "$dir" \
    -GCODED_W="${w}" -GCODED_H=32 -GFRAME_W="${w}" -GFRAME_H=32 \
    -GDISP_W="${w}" -GDISP_H=24 -GPRESENT_X=0 \
    -GPHYS_BASE="${phys}" -GBANK_STRIDE="${stride}" -GDOORBELL="${db}" \
    -CFLAGS "-std=c++17 -O2 -DLAG_CODED_W=${w}" \
    -o Vlag
  set +e
  out="$("$dir/Vlag" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "lag_${w} true rc=$rc"
  [[ "$rc" -eq 0 ]]
  echo "$out" | grep -q "PASS B12"
  echo "$out" | grep -q "B12_LAG coded_w=${w}"
  lag=$(echo "$out" | sed -n 's/.*lag_cycles=\([0-9]*\).*/\1/p' | head -1)
  echo "MEASURED_LAG coded_w=${w} lag_cycles=${lag}"
  echo "$lag" > "$dir/lag.txt"
}

echo "=== 960 geometry ==="
run_one 960 build/verilator/b12_lag_960
echo "=== 624 geometry ==="
run_one 624 build/verilator/b12_lag_624
l960=$(cat build/verilator/b12_lag_960/lag.txt)
l624=$(cat build/verilator/b12_lag_624/lag.txt)
echo "B12_COMPARE lag960=${l960} lag624=${l624}"
echo "PASS test_ddr_store_rgb_lag"
