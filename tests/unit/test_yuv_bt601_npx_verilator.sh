#!/usr/bin/env bash
# Red-before-green Verilator cosim for yuv_bt601_npx + present_beam_ppc.
# No Quartus fit. No device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="${VERILATOR:-}"
if [[ -z "$RUN_VERILATOR" ]]; then
  if [[ -x "$ROOT/scripts/run_verilator.sh" ]]; then
    RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
  elif command -v verilator >/dev/null 2>&1; then
    RUN_VERILATOR="$(command -v verilator)"
  fi
fi
if [[ -z "${RUN_VERILATOR}" ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
fi

OUT="$ROOT/build/verilator/multi_pixel_npx"
mkdir -p "$OUT"
RTL_Y="$ROOT/fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv"
RTL_B="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_ppc.sv"
TB_Y="$ROOT/tests/rtl/yuv_bt601_npx_tb.sv"
TB_B="$ROOT/tests/rtl/present_beam_ppc_tb.sv"

echo "RTL SIM: $($RUN_VERILATOR --version 2>&1 | head -1)"

# --- yuv: RED wrong R coeff must detect mismatch (log SoT; $finish may be rc=0) ---
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module yuv_bt601_npx_tb \
  -GRED_WRONG_R_COEFF=1 \
  -Mdir "$OUT/yuv_red" \
  "$TB_Y" "$RTL_Y" >/dev/null
set +e
"$OUT/yuv_red/Vyuv_bt601_npx_tb" >"$OUT/yuv_red.log" 2>&1
set -e
grep -q 'PASS yuv_bt601_npx RED' "$OUT/yuv_red.log" || {
  cat "$OUT/yuv_red.log"
  echo "FAIL: yuv red missing PASS RED line" >&2
  exit 1
}
grep -q 'FAIL v-push' "$OUT/yuv_red.log" || {
  cat "$OUT/yuv_red.log"
  echo "FAIL: yuv red must show coeff mismatch on v-push" >&2
  exit 1
}
# Must NOT claim green PASS
if grep -q 'PASS yuv_bt601_npx N=1 matches' "$OUT/yuv_red.log"; then
  cat "$OUT/yuv_red.log"
  echo "FAIL: yuv red must not print green PASS" >&2
  exit 1
fi
echo "OK yuv RED"

# --- yuv: GREEN ---
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module yuv_bt601_npx_tb \
  -GRED_WRONG_R_COEFF=0 \
  -Mdir "$OUT/yuv_green" \
  "$TB_Y" "$RTL_Y" >/dev/null
set +e
"$OUT/yuv_green/Vyuv_bt601_npx_tb" >"$OUT/yuv_green.log" 2>&1
grc=$?
set -e
grep -q 'PASS yuv_bt601_npx N=1 matches BT.601 golden' "$OUT/yuv_green.log" || {
  cat "$OUT/yuv_green.log"
  echo "FAIL: yuv green" >&2
  exit 1
}
if grep -q '^FAIL ' "$OUT/yuv_green.log"; then
  cat "$OUT/yuv_green.log"
  echo "FAIL: yuv green log contains FAIL" >&2
  exit 1
fi
echo "OK yuv GREEN rc=$grc"

# --- beam: RED expect step=1 with PPC=4 ---
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_beam_ppc_tb \
  -GPX_PER_CLK=4 -GRED_STEP1=1 \
  -Mdir "$OUT/beam_red" \
  "$TB_B" "$RTL_B" >/dev/null
set +e
"$OUT/beam_red/Vpresent_beam_ppc_tb" >"$OUT/beam_red.log" 2>&1
set -e
grep -q 'PASS present_beam_ppc RED' "$OUT/beam_red.log" || {
  cat "$OUT/beam_red.log"
  echo "FAIL: beam red missing PASS RED" >&2
  exit 1
}
if grep -q 'PASS present_beam_ppc ppc=4' "$OUT/beam_red.log"; then
  cat "$OUT/beam_red.log"
  echo "FAIL: beam red must not print green PASS" >&2
  exit 1
fi
echo "OK beam RED"

# --- beam: GREEN PPC=4 ---
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_beam_ppc_tb \
  -GPX_PER_CLK=4 -GRED_STEP1=0 \
  -Mdir "$OUT/beam_green" \
  "$TB_B" "$RTL_B" >/dev/null
set +e
"$OUT/beam_green/Vpresent_beam_ppc_tb" >"$OUT/beam_green.log" 2>&1
brc=$?
set -e
grep -q 'PASS present_beam_ppc ppc=4' "$OUT/beam_green.log" || {
  cat "$OUT/beam_green.log"
  echo "FAIL: beam green" >&2
  exit 1
}
if grep -q '^FAIL ' "$OUT/beam_green.log"; then
  cat "$OUT/beam_green.log"
  echo "FAIL: beam green log contains FAIL" >&2
  exit 1
fi
echo "OK beam GREEN rc=$brc"
echo "PASS test_yuv_bt601_npx_verilator"
