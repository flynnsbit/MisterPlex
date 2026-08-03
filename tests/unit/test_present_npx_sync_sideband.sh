#!/usr/bin/env bash
# Dual-clock INCLUDE_SYNC=1 sideband conservation (no device).
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

OUT="$ROOT/build/verilator/present_npx_sync_sideband"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_npx_sync_sideband_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)

echo "RTL SIM: $($RUN_VERILATOR --version 2>&1 | head -1)"
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_sync_sideband_tb \
  -GPX_PER_CLK=2 -GN_GROUPS=512 \
  -Mdir "$OUT" "${SRCS[@]}" >/dev/null
set +e
"$OUT/Vpresent_npx_sync_sideband_tb" >"$OUT/log.txt" 2>&1
rc=$?
set -e
grep -q 'PASS present_npx_sync_sideband' "$OUT/log.txt" || {
  cat "$OUT/log.txt"
  echo "FAIL present_npx_sync_sideband" >&2
  exit 1
}
echo "PASS test_present_npx_sync_sideband true rc=$rc"
exit 0
