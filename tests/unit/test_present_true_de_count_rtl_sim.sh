#!/usr/bin/env bash
# Counted true-DE + B6 store coordinate oracle + multi-geom (320/640/960).
# Soft-skip≠PASS. true rc direct.
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
  "store_id_checked=518400" "oracle_full=1" "visit_unique=518400" \
  "visit_dup=0" "visit_omit=0" "store_x_range=0..959" "store_y_range=0..539" \
  "PASS true_de_count"
[[ "$RC30" -eq 0 ]] || exit 1

# --- PRODUCT 24 ---
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
  "oracle_full=1" "store_id_checked=518400" "visit_unique=518400" \
  "PASS true_de_count"
[[ "$RC24" -eq 0 ]] || exit 1
grep -qE 'fps@20M=24\.00' <<<"$OUT24" || { echo "FAIL fps not ~24" >&2; exit 1; }

# --- Multi-geom 320 / 640 / 960 ---
for geom in 320 640 960; do
  case "$geom" in
    320) def=PRESENT_BEAM_GEOM_320; want_w=320; want_h=240; pix=76800 ;;
    640) def=PRESENT_BEAM_GEOM_640; want_w=640; want_h=360; pix=230400 ;;
    960) def=PRESENT_BEAM_GEOM_960; want_w=960; want_h=540; pix=518400 ;;
  esac
  BG="$ROOT/build/verilator/present_true_de_count_g${geom}"
  run_build "$BG" -CFLAGS "-std=c++17 -O2 -D${def}" +define+${def}
  set +e
  OUTG="$("$BG/Vpresent_true_de_count_tb" 2>&1)"; RCG=$?
  set -e
  printf '%s\n' "$OUTG"
  echo "geom${geom} true rc=$RCG"
  assert_exec "geom${geom}" "$OUTG" \
    "CASE true_de_count EXECUTED" "oracle_full=1" "true_de=1" \
    "store_id_checked=${pix}" "visit_unique=${pix}" "visit_dup=0" \
    "PASS true_de_count"
  grep -qE "de_w_max=${want_w}" <<<"$OUTG" || { echo "FAIL geom${geom} de_w" >&2; exit 1; }
  grep -qE "de_lines=${want_h}" <<<"$OUTG" || { echo "FAIL geom${geom} de_h" >&2; exit 1; }
  [[ "$RCG" -eq 0 ]] || exit 1
  echo "OK GEOM ${want_w}x${want_h} oracle_full"
done

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
grep -q "true_de=0" <<<"$OUTI" || { echo "FAIL island true_de" >&2; exit 1; }
echo "PASS red-check ISLAND_1280 true_rc=$RCI"

# --- RED V_TOT bad DE ---
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
echo "PASS red-check FAULT_VTOT_BAD_DE true_rc=$RCV"

# --- B6 RED store oracle PERM ---
BP="$ROOT/build/verilator/present_true_de_count_oracle_perm"
run_build "$BP" -CFLAGS "-std=c++17 -O2 -DPRESENT_BEAM_FAULT_STORE_ORACLE_PERM" \
  +define+PRESENT_BEAM_FAULT_STORE_ORACLE_PERM
set +e
OUTP="$("$BP/Vpresent_true_de_count_tb" 2>&1)"; RCP=$?
set -e
printf '%s\n' "$OUTP"
echo "oracle_perm true rc=$RCP"
assert_exec oracle_perm "$OUTP" \
  "CASE true_de_count EXECUTED" "mode=FAULT_STORE_ORACLE_PERM" \
  "oracle_full=0"
[[ "$RCP" -ne 0 ]] || { echo "FAIL PERM must RED" >&2; exit 1; }
# Must not greenwash: identity broken
grep -qE 'store_id_ok=0|store_id_fail=[1-9]' <<<"$OUTP" || {
  echo "FAIL PERM did not break identity" >&2; exit 1; }
echo "PASS red-check FAULT_STORE_ORACLE_PERM true_rc=$RCP"

# --- B6 RED store oracle DROP ---
BD="$ROOT/build/verilator/present_true_de_count_oracle_drop"
run_build "$BD" -CFLAGS "-std=c++17 -O2 -DPRESENT_BEAM_FAULT_STORE_ORACLE_DROP" \
  +define+PRESENT_BEAM_FAULT_STORE_ORACLE_DROP
set +e
OUTD="$("$BD/Vpresent_true_de_count_tb" 2>&1)"; RCD=$?
set -e
printf '%s\n' "$OUTD"
echo "oracle_drop true rc=$RCD"
assert_exec oracle_drop "$OUTD" \
  "CASE true_de_count EXECUTED" "mode=FAULT_STORE_ORACLE_DROP" \
  "oracle_full=0"
[[ "$RCD" -ne 0 ]] || { echo "FAIL DROP must RED" >&2; exit 1; }
grep -qE 'visit_dup=[1-9]|visit_omit=[1-9]|store_x0=0' <<<"$OUTD" || {
  echo "FAIL DROP did not show miss/dup" >&2; exit 1; }
echo "PASS red-check FAULT_STORE_ORACLE_DROP true_rc=$RCD"

echo "OK present_true_de_count: B6 oracle + 30/24 + geom 320/640/960 + RED island/vtot/perm/drop"
exit 0
