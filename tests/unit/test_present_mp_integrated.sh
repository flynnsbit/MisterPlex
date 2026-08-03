#!/usr/bin/env bash
# Integrated beam→mock-store→tag→npx (rd-duck integration class).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -x "$ROOT/scripts/run_verilator.sh" ]]; then
  RV="$ROOT/scripts/run_verilator.sh"
elif command -v verilator >/dev/null 2>&1; then
  RV="$(command -v verilator)"
else
  echo "SKIP-NOT-PASS: Verilator missing" >&2
  exit 77
fi
OUT="$ROOT/build/verilator/present_mp_integrated"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_mp_integrated_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_beam_ppc.sv"
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
  grep -q "$pat" "$OUT/$name.log" || { tail -30 "$OUT/$name.log"; echo "FAIL $name"; exit 1; }
  echo "OK $name rc=$rc"
}
run_one no_frame "PASS present_mp_integrated NO_FRAME" -GHAS_FRAME=0
run_one with_frame "PASS present_mp_integrated FRAME" -GHAS_FRAME=1
echo "PASS test_present_mp_integrated"
exit 0
