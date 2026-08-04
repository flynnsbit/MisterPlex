#!/usr/bin/env bash
# B5: beam + content_window + ddr_frame_store under PRESENT_BEAM_960.
# PRODUCT_LEGACY must FAIL (STORE_LEGACY_SHAPE / accepted!=518400).
# TB_LOCAL_960 experimental may PASS accepted==518400 (NOT product svh).
# RED_STARVE must fire underrun (rc!=0).
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

RTL="$ROOT/fpga/Plex_MiSTer/rtl"
sv_common=(
  "$ROOT/tests/rtl/present_beam_ddr_store_tb_top.sv"
  "$RTL/present_beam_content_de.sv"
  "$RTL/present_content_window.sv"
  "$RTL/ddr_frame_store.sv"
  "$RTL/ddr_bank_geom_guard.sv"
  "$RTL/line_buf_ram.sv"
  "$RTL/async_fifo.sv"
  "$ROOT/tests/rtl/present_beam_ddr_store_tb.cpp"
)
base_flags=(
  --cc --exe --build --top-module present_beam_ddr_store_tb
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-SELRANGE -Wno-UNSIGNED
  +incdir+"$RTL"
)

build_run() {
  local label="$1" mdir="$2"; shift 2
  mkdir -p "$mdir"
  echo "=== BUILD $label ===" >&2
  "$RUN" "${base_flags[@]}" -CFLAGS "-std=c++17 -O2" "$@" --Mdir "$mdir" "${sv_common[@]}"
  set +e
  local out rc
  out="$("$mdir/Vpresent_beam_ddr_store_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${label} true rc=$rc"
  printf '%s\n' "$out"
  echo "$rc"
}

# --- 1) PRODUCT_LEGACY: must rc!=0, STORE_LEGACY_SHAPE ---
B1="$ROOT/build/verilator/present_beam_ddr_legacy"
mkdir -p "$B1"
echo "=== BUILD PRODUCT_LEGACY ===" >&2
"$RUN" "${base_flags[@]}" -CFLAGS "-std=c++17 -O2" --Mdir "$B1" "${sv_common[@]}"
set +e
OUT1="$("$B1/Vpresent_beam_ddr_store_tb" LEGACY 2>&1)"; RC1=$?
set -e
printf '%s\n' "$OUT1"
echo "PRODUCT_LEGACY true rc=$RC1"
assert_exec PRODUCT_LEGACY "$OUT1" \
  "CASE PRODUCT_LEGACY EXECUTED" \
  "STORE_LEGACY_SHAPE=1" \
  "de_raster_960x540" \
  "store_req_full_518400"
[[ "$RC1" -ne 0 ]] || { echo "FAIL PRODUCT_LEGACY must not be green" >&2; exit 1; }
grep -q "STORE_LEGACY_SHAPE" <<<"$OUT1" || { echo "FAIL missing STORE_LEGACY_SHAPE" >&2; exit 1; }
grep -q "B5_PRODUCT_NOT_READY" <<<"$OUT1" || { echo "FAIL missing NOT_READY verdict" >&2; exit 1; }
# Must not claim full accept on legacy
if grep -qE 'store_accepted=518400' <<<"$OUT1" && grep -q 'acc_full=1' <<<"$OUT1"; then
  echo "FAIL PRODUCT_LEGACY false green accepted=518400" >&2
  exit 1
fi
echo "OK PRODUCT_LEGACY honest FAIL"

# --- 2) TB_LOCAL_960 experimental ---
B2="$ROOT/build/verilator/present_beam_ddr_tb960"
mkdir -p "$B2"
echo "=== BUILD TB_LOCAL_960 ===" >&2
"$RUN" "${base_flags[@]}" +define+BEAM_DDR_TB_LOCAL_960 \
  -CFLAGS "-std=c++17 -O2 -DBEAM_DDR_TB_LOCAL_960" \
  --Mdir "$B2" "${sv_common[@]}"
set +e
OUT2="$("$B2/Vpresent_beam_ddr_store_tb" TB960 2>&1)"; RC2=$?
set -e
printf '%s\n' "$OUT2"
echo "TB_LOCAL_960 true rc=$RC2"
assert_exec TB_LOCAL_960 "$OUT2" \
  "CASE TB_LOCAL_960 EXECUTED" \
  "TB_LOCAL_960_NOT_PRODUCT_SVH" \
  "shape_960=1"
if [[ "$RC2" -eq 0 ]]; then
  assert_exec TB_LOCAL_960_green "$OUT2" \
    "store_accepted=518400" \
    "acc_full=1" \
    "underrun" \
    "PASS store_accepted_full_518400" \
    "PASS rd_underrun_clear" \
    "OVERALL PASS"
  # Denominator N check
  grep -qE 'store_accepted=518400' <<<"$OUT2" || { echo "FAIL accepted N" >&2; exit 1; }
  echo "OK TB_LOCAL_960 green (experimental, not product svh)"
else
  echo "TB_LOCAL_960 not green yet (true rc=$RC2) — print for RCA; still require EXECUTED" >&2
  # Do not soft-pass. Experimental green is desired; if red, fail the gate so we fix it.
  exit 1
fi

# --- 3) RED STARVE ---
B3="$ROOT/build/verilator/present_beam_ddr_starve"
mkdir -p "$B3"
echo "=== BUILD RED_STARVE ===" >&2
"$RUN" "${base_flags[@]}" +define+BEAM_DDR_TB_LOCAL_960 \
  -CFLAGS "-std=c++17 -O2 -DBEAM_DDR_TB_LOCAL_960" \
  --Mdir "$B3" "${sv_common[@]}"
set +e
OUT3="$("$B3/Vpresent_beam_ddr_store_tb" STARVE 2>&1)"; RC3=$?
set -e
printf '%s\n' "$OUT3"
echo "RED_STARVE true rc=$RC3"
assert_exec RED_STARVE "$OUT3" \
  "CASE RED_STARVE EXECUTED" \
  "UNDERRUN_FIRED"
[[ "$RC3" -ne 0 ]] || { echo "FAIL STARVE must rc!=0" >&2; exit 1; }
grep -q "PASS UNDERRUN_FIRED" <<<"$OUT3" || {
  # accept FAIL UNDERRUN_FIRED as test failure
  if grep -q "FAIL UNDERRUN_FIRED" <<<"$OUT3"; then
    echo "FAIL underrun did not fire — unfalsifiable clear" >&2
    exit 1
  fi
  echo "FAIL UNDERRUN_FIRED marker missing" >&2
  exit 1
}
echo "OK RED_STARVE underrun fired"

# --- 4) TB_LOCAL_720x480 capacity-tight ---
B4="$ROOT/build/verilator/present_beam_ddr_tb720"
mkdir -p "$B4"
echo "=== BUILD TB_LOCAL_720x480 ===" >&2
"$RUN" "${base_flags[@]}" +define+BEAM_DDR_TB_LOCAL_720x480 \
  -CFLAGS "-std=c++17 -O2 -DBEAM_DDR_TB_LOCAL_720x480" \
  --Mdir "$B4" "${sv_common[@]}"
set +e
OUT4="$("$B4/Vpresent_beam_ddr_store_tb" TB720 2>&1)"; RC4=$?
set -e
printf '%s\n' "$OUT4"
echo "TB_LOCAL_720x480 true rc=$RC4"
assert_exec TB_LOCAL_720x480 "$OUT4" \
  "CASE TB_LOCAL_720x480 EXECUTED" \
  "i420_bytes=518400" \
  "usable=0x7f000" \
  "capacity_ok=1" \
  "align16_ok=1" \
  "shape_720=1"
[[ "$RC4" -eq 0 ]] || { echo "FAIL TB720 must green" >&2; exit 1; }
assert_exec TB720_green "$OUT4" \
  "store_accepted=345600" \
  "acc_full=1" \
  "de_pixels=345600" \
  "PASS store_accepted_full_345600" \
  "PASS spare_1792" \
  "OVERALL PASS"
echo "OK TB_LOCAL_720x480 capacity-tight green"

# --- 5) RED NON16 468×360 ---
B5="$ROOT/build/verilator/present_beam_ddr_non16"
mkdir -p "$B5"
echo "=== BUILD RED_NON16 ===" >&2
"$RUN" "${base_flags[@]}" +define+BEAM_DDR_FAULT_NON16 \
  -CFLAGS "-std=c++17 -O2 -DBEAM_DDR_FAULT_NON16" \
  --Mdir "$B5" "${sv_common[@]}"
set +e
OUT5="$("$B5/Vpresent_beam_ddr_store_tb" NON16 2>&1)"; RC5=$?
set -e
printf '%s\n' "$OUT5"
echo "RED_NON16 true rc=$RC5"
assert_exec RED_NON16 "$OUT5" \
  "CASE RED_NON16 EXECUTED" \
  "align16_ok=0" \
  "coded_468x360"
[[ "$RC5" -ne 0 ]] || { echo "FAIL NON16 must rc!=0 (loud reject)" >&2; exit 1; }
# Two valid RED outcomes:
#   NOT_FULL_ACCEPT — store/underrun path already broken (good)
#   FALSE_GREEN     — store full-accepted non-16 (shear class); twin must still rc!=0
if grep -q "FAIL NON16_FALSE_GREEN" <<<"$OUT5"; then
  echo "PASS red-check NON16 caught STORE_FALSE_GREEN (shear; store does not reject non-16)"
elif grep -q "PASS NON16_NOT_FULL_ACCEPT" <<<"$OUT5"; then
  echo "PASS red-check NON16 not full accept"
else
  echo "FAIL NON16 missing accept verdict" >&2
  exit 1
fi
echo "OK RED_NON16 loud reject true_rc=$RC5"

echo "OK B5 present_beam_ddr_store: LEGACY + TB960 + TB720 + STARVE + NON16"
exit 0
