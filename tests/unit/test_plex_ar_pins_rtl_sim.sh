#!/usr/bin/env bash
# B9: Plex.sv VIDEO_ARX/VIDEO_ARY top-level pin policy.
# Soft-skip ≠ PASS. true rc direct.
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

# --- Static: Plex.sv must drive pins via plex_video_ar (not bare 4/3 assign) ---
PLEX="$ROOT/fpga/Plex_MiSTer/Plex.sv"
grep -q 'plex_video_ar u_plex_video_ar' "$PLEX" || {
  echo "FAIL Plex.sv missing u_plex_video_ar instance" >&2; exit 1; }
grep -q '\.VIDEO_ARX(VIDEO_ARX)' "$PLEX" || {
  echo "FAIL Plex.sv must wire .VIDEO_ARX(VIDEO_ARX)" >&2; exit 1; }
grep -q '\.VIDEO_ARY(VIDEO_ARY)' "$PLEX" || {
  echo "FAIL Plex.sv must wire .VIDEO_ARY(VIDEO_ARY)" >&2; exit 1; }
# Bare legacy assign must be gone (B9 defect source).
if grep -nE 'assign[[:space:]]+VIDEO_ARX[[:space:]]*=' "$PLEX" | grep -v 'plex_video'; then
  echo "FAIL Plex.sv still has bare assign VIDEO_ARX" >&2
  exit 1
fi
# files.qip lists module
grep -q 'rtl/plex_video_ar.sv' "$ROOT/fpga/Plex_MiSTer/files.qip" || {
  echo "FAIL files.qip missing plex_video_ar.sv" >&2; exit 1; }
echo "PASS Plex.sv AR pin wiring + qip"

sv=(
  "$ROOT/tests/rtl/plex_ar_pins_tb_top.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_video_ar.sv"
  "$ROOT/tests/rtl/plex_ar_pins_tb.cpp"
)
B="$ROOT/build/verilator/plex_ar_pins"
mkdir -p "$B"
"$RUN" --cc --exe --build --top-module plex_ar_pins_tb \
  -Wno-fatal -CFLAGS "-std=c++17 -O2" --Mdir "$B" "${sv[@]}"

run_case() {
  local arg="$1"; shift
  set +e
  local out rc
  out="$("$B/Vplex_ar_pins_tb" "$arg" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  echo "${arg} true rc=$rc"
  assert_exec "$arg" "$out" "CASE plex_ar_pins EXECUTED"
  local m
  for m in "$@"; do
    grep -q -- "$m" <<<"$out" || { echo "FAIL $arg missing $m" >&2; exit 1; }
  done
  [[ "$rc" -eq 0 ]] || exit 1
}

# Greens: modes must differ (checked inside TB) + expected pins
run_case ORIG_16_9 "PASS pins_16_9" "PASS ORIG_16x9_differs_FULL" \
  "PASS ORIG_16x9_differs_ORIG_noDAR" "PASS plex_ar_pins"

run_case FULL "PASS pins_0_0" "PASS plex_ar_pins"

run_case ORIG_4_3 "PASS pins_4_3_from_host_DAR" "PASS plex_ar_pins"

run_case ARC1 "PASS pins_ARC1_1_0" "PASS FULL_differs_ARC1" "PASS plex_ar_pins"

# RED: 16:9 content, Original, no host DAR → 4:3 pins (the user-visible defect)
set +e
OUTR="$("$B/Vplex_ar_pins_tb" RED_16_9_AS_4_3 2>&1)"; RCR=$?
set -e
printf '%s\n' "$OUTR"
echo "RED_16_9_AS_4_3 true rc=$RCR"
assert_exec RED "$OUTR" "CASE plex_ar_pins EXECUTED" "RED_catches_4_3_on_16_9_content"
[[ "$RCR" -ne 0 ]] || { echo "FAIL RED must rc!=0" >&2; exit 1; }
echo "PASS red-check RED_16_9_AS_4_3 true_rc=$RCR"

# RED: inference from coded 720×480 is unsound — host DAR must win; twin exits RED
set +e
OUTI="$("$B/Vplex_ar_pins_tb" RED_INFER_CODED 2>&1)"; RCI=$?
set -e
printf '%s\n' "$OUTI"
echo "RED_INFER_CODED true rc=$RCI"
assert_exec RED_INFER "$OUTI" "CASE plex_ar_pins EXECUTED" "PASS host_DAR_wins" \
  "PASS pins_not_equal_storage_AR_3_2"
[[ "$RCI" -ne 0 ]] || { echo "FAIL INFER twin must rc!=0" >&2; exit 1; }
echo "PASS red-check RED_INFER_CODED true_rc=$RCI"

echo "OK B9 plex_ar_pins: ORIG 16:9 / FULL 0:0 / ARC1 + RED 4:3-on-16:9 + no coded-infer"
exit 0
