#!/usr/bin/env bash
# Counted true-DE RTL sim: product 960×540 + RED island 1280.
set -euo pipefail

assert_exec() {
  local label="$1" log="$2"; shift 2
  local m missing=0
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing: $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e
VER="$($RUN --version 2>&1)"; VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  exit 3
fi
[[ "$VRC" -eq 0 ]] || exit "$VRC"

echo "RTL SIM: $VER" >&2
sv=(
  "$ROOT/tests/rtl/present_true_de_count_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv"
  "$ROOT/tests/rtl/present_true_de_count_tb.cpp"
)
vf=(--cc --exe --build --top-module present_true_de_count_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -CFLAGS "-std=c++17 -O2")

BUILD="$ROOT/build/verilator/present_true_de_count"
mkdir -p "$BUILD"
echo "=== BUILD product true_de_count ===" >&2
"$RUN" "${vf[@]}" --Mdir "$BUILD" "${sv[@]}"

set +e
OUT="$("$BUILD/Vpresent_true_de_count_tb" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "product true rc=$RC"
assert_exec product "$OUT" \
  "CASE true_de_count EXECUTED" \
  "mode=PRODUCT_960" \
  "true_de=1" \
  "PASS true_de_count" \
  "de_w_max=960" \
  "de_lines=540"
[[ "$RC" -eq 0 ]] || exit 1

# RED island — +define for SV beam params AND -D for C++ expect/mode.
BD="$ROOT/build/verilator/present_true_de_count_island"
mkdir -p "$BD"
echo "=== RED PRESENT_BEAM_FAULT_ISLAND_1280 ===" >&2
"$RUN" --cc --exe --build --top-module present_true_de_count_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2 -DPRESENT_BEAM_FAULT_ISLAND_1280" \
  --Mdir "$BD" +define+PRESENT_BEAM_FAULT_ISLAND_1280 "${sv[@]}"
set +e
IOUT="$("$BD/Vpresent_true_de_count_tb" 2>&1)"; IRC=$?
set -e
printf '%s\n' "$IOUT"
echo "island true rc=$IRC"
assert_exec island "$IOUT" "CASE true_de_count EXECUTED" "mode=ISLAND_1280"
if [[ "$IRC" -eq 0 ]]; then
  echo "FAIL: island config must not PASS" >&2
  exit 1
fi
# Must have observed canvas DE width
grep -q "de_w_max=1280" <<<"$IOUT" || { echo "FAIL missing de_w_max=1280" >&2; exit 1; }
grep -q "true_de=0" <<<"$IOUT" || { echo "FAIL island true_de not 0" >&2; exit 1; }
echo "PASS red-check PRESENT_BEAM_FAULT_ISLAND_1280 true_rc=$IRC"

echo "OK present_true_de_count_rtl_sim: counted 960x540 + RED island1280"
exit 0
