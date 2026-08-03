#!/usr/bin/env bash
# Counted true-DE RTL sim: product 30 + product 24(V705) + RED island + RED vtot/bad-DE.
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

run_build() {
  local mdir="$1"; shift
  mkdir -p "$mdir"
  "$RUN" --cc --exe --build --top-module present_true_de_count_tb \
    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    "$@" --Mdir "$mdir" "${sv[@]}"
}

run_case() {
  local label="$1" mdir="$2" bin="$3"
  shift 3
  echo "=== $label ===" >&2
  run_build "$mdir" "$@"
  set +e
  local out rc
  out="$("$bin" 2>&1)"; rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${label} true rc=$rc"
  assert_exec "$label" "$out" "CASE true_de_count EXECUTED"
  printf '%s\n' "$out"
  echo "$rc"
}

# --- PRODUCT 30 ---
B30="$ROOT/build/verilator/present_true_de_count"
run_build "$B30" -CFLAGS "-std=c++17 -O2"
set +e
OUT30="$("$B30/Vpresent_true_de_count_tb" 2>&1)"; RC30=$?
set -e
printf '%s\n' "$OUT30"
echo "product30 true rc=$RC30"
assert_exec product30 "$OUT30" \
  "CASE true_de_count EXECUTED" "mode=PRODUCT_30_V564" "true_de=1" \
  "de_w_max=960" "de_lines=540" "PASS true_de_count"
[[ "$RC30" -eq 0 ]] || exit 1

# --- PRODUCT 24 V_TOT=705 ---
B24="$ROOT/build/verilator/present_true_de_count_24"
run_build "$B24" -CFLAGS "-std=c++17 -O2 -DPRESENT_BEAM_24_V705" \
  +define+PRESENT_BEAM_24_V705
set +e
OUT24="$("$B24/Vpresent_true_de_count_tb" 2>&1)"; RC24=$?
set -e
printf '%s\n' "$OUT24"
echo "product24 true rc=$RC24"
assert_exec product24 "$OUT24" \
  "CASE true_de_count EXECUTED" "mode=PRODUCT_24_V705" "true_de=1" \
  "de_w_max=960" "de_lines=540" "V_TOT=705" "rt_vt=705" "PASS true_de_count"
[[ "$RC24" -eq 0 ]] || exit 1
# fps pin
grep -qE 'fps@20M=24\.00' <<<"$OUT24" || { echo "FAIL fps not ~24" >&2; exit 1; }

# --- RED island ---
BI="$ROOT/build/verilator/present_true_de_count_island"
run_build "$BI" -CFLAGS "-std=c++17 -O2 -DPRESENT_BEAM_FAULT_ISLAND_1280" \
  +define+PRESENT_BEAM_FAULT_ISLAND_1280
set +e
OUTI="$("$BI/Vpresent_true_de_count_tb" 2>&1)"; RCI=$?
set -e
printf '%s\n' "$OUTI"
echo "island true rc=$RCI"
assert_exec island "$OUTI" "CASE true_de_count EXECUTED" "mode=ISLAND_1280"
[[ "$RCI" -ne 0 ]] || { echo "FAIL island must RED" >&2; exit 1; }
grep -q "de_w_max=1280" <<<"$OUTI" || { echo "FAIL island width" >&2; exit 1; }
grep -q "true_de=0" <<<"$OUTI" || { echo "FAIL island true_de" >&2; exit 1; }
echo "PASS red-check ISLAND_1280 true_rc=$RCI"

# --- RED V_TOT=705 with bad DE width ---
BV="$ROOT/build/verilator/present_true_de_count_vtot_bad"
run_build "$BV" -CFLAGS "-std=c++17 -O2 -DPRESENT_BEAM_FAULT_VTOT_BAD_DE" \
  +define+PRESENT_BEAM_FAULT_VTOT_BAD_DE
set +e
OUTV="$("$BV/Vpresent_true_de_count_tb" 2>&1)"; RCV=$?
set -e
printf '%s\n' "$OUTV"
echo "vtot_bad_de true rc=$RCV"
assert_exec vtot_bad "$OUTV" "CASE true_de_count EXECUTED" "mode=FAULT_VTOT_BAD_DE"
[[ "$RCV" -ne 0 ]] || { echo "FAIL vtot_bad_de must RED" >&2; exit 1; }
grep -q "true_de=0" <<<"$OUTV" || { echo "FAIL vtot_bad true_de" >&2; exit 1; }
grep -q "de_w_max=1280" <<<"$OUTV" || { echo "FAIL vtot_bad still wide DE" >&2; exit 1; }
grep -q "V_TOT=705" <<<"$OUTV" || { echo "FAIL vtot_bad V_TOT" >&2; exit 1; }
echo "PASS red-check FAULT_VTOT_BAD_DE true_rc=$RCV"

echo "OK present_true_de_count_rtl_sim: 30+24 counted true_de + RED island/vtot"
exit 0
