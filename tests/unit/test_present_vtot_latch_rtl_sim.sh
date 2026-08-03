#!/usr/bin/env bash
# Frame-boundary V_TOTAL latch: adversarial mid-frame 705→564 must not stall.
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
B="$ROOT/build/verilator/present_vtot_latch"
mkdir -p "$B"
"$RUN" --cc --exe --build --top-module present_true_de_count_tb \
  -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17 -O2" \
  --Mdir "$B" \
  "$ROOT/tests/rtl/present_true_de_count_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_content_window.sv" \
  "$ROOT/tests/rtl/present_vtot_latch_tb.cpp"

set +e
OUT="$("$B/Vpresent_true_de_count_tb" 2>&1)"; RC=$?
set -e
printf '%s\n' "$OUT"
echo "vtot_latch true rc=$RC"
assert_exec vtot_latch "$OUT" \
  "CASE vtot_latch EXECUTED" "mode=MIDFRAME_705_to_564" \
  "vtot_before=705" "vtot_at_fs=564" "PASS vtot_latch"
[[ "$RC" -eq 0 ]] || exit 1
echo "OK present_vtot_latch_rtl_sim"
exit 0
