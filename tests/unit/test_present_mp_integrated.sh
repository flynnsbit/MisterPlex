#!/usr/bin/env bash
# Integrated beam→rate_match→mock-store→ordered-tag→npx
# GREEN + RED_DUAL_OR + RED_BAD_LAT (store-only extra delay).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -x "$ROOT/scripts/run_verilator.sh" ]]; then RV="$ROOT/scripts/run_verilator.sh"
elif command -v verilator >/dev/null 2>&1; then RV="$(command -v verilator)"
else echo "SKIP-NOT-PASS: Verilator missing" >&2; exit 77; fi
OUT="$ROOT/build/verilator/present_mp_integrated"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_mp_integrated_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_ppc.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_pix_rate_match.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)
echo "RTL SIM: $($RV --version 2>&1 | head -1)"
run_one() {
  local name="$1" pat="$2"; shift 2
  rm -rf "$OUT/$name"
  "$RV" -Wno-fatal --binary --timing --top-module present_mp_integrated_tb \
    "$@" -Mdir "$OUT/$name" "${SRCS[@]}" >/dev/null
  set +e
  "$OUT/$name/Vpresent_mp_integrated_tb" >"$OUT/$name.log" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    tail -40 "$OUT/$name.log"
    echo "FAIL $name nonzero rc=$rc (marker alone is not enough)" >&2
    exit 1
  fi
  grep -q "$pat" "$OUT/$name.log" || {
    tail -40 "$OUT/$name.log"
    echo "FAIL $name missing '$pat' rc=$rc" >&2
    exit 1
  }
  echo "OK $name rc=$rc"
}
run_one no_frame "PASS present_mp_integrated NO_FRAME" -GHAS_FRAME=0
run_one with_frame "PASS present_mp_integrated FRAME" -GHAS_FRAME=1
run_one red_dual_or "PASS present_mp_integrated RED_DUAL_OR" -GHAS_FRAME=1 -GRED_DUAL_OR=1
run_one red_bad_lat "PASS present_mp_integrated RED_BAD_LAT" -GHAS_FRAME=1 -GRED_BAD_LAT=1
echo "PASS test_present_mp_integrated"
exit 0
