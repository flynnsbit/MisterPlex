#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RV="${ROOT}/scripts/run_verilator.sh"
command -v "$RV" >/dev/null || RV=$(command -v verilator)
OUT="$ROOT/build/verilator/present_npx_af_conserve"
mkdir -p "$OUT"
rm -rf "$OUT/run"
"$RV" -Wno-fatal --binary --timing --top-module present_npx_af_conserve_tb \
  -Mdir "$OUT/run" \
  "$ROOT/tests/rtl/present_npx_af_conserve_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv" >/dev/null
set +e
"$OUT/run/Vpresent_npx_af_conserve_tb" >"$OUT/run.log" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then tail -40 "$OUT/run.log"; echo "FAIL rc=$rc"; exit 1; fi
grep -q "PASS present_npx_af_conserve" "$OUT/run.log" || { tail -40 "$OUT/run.log"; exit 1; }
echo "PASS test_present_npx_af_conserve rc=$rc"
exit 0
