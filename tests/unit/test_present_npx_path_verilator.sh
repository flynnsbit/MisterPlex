#!/usr/bin/env bash
# Red-before-green: present_npx_path N-wide → 1-wide beat conservation.
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

OUT="$ROOT/build/verilator/present_npx_path"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_npx_path_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)

echo "RTL SIM: $($RUN_VERILATOR --version 2>&1 | head -1)"

# RED: drop read counting → conservation must fail path
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_path_tb \
  -GPX_PER_CLK=4 -GRED_DROP_READ=1 \
  -Mdir "$OUT/red" "${SRCS[@]}" >/dev/null
set +e
"$OUT/red/Vpresent_npx_path_tb" >"$OUT/red.log" 2>&1
set -e
grep -q 'PASS present_npx_path RED' "$OUT/red.log" || {
  cat "$OUT/red.log"
  echo "FAIL: missing RED PASS" >&2
  exit 1
}
if grep -q 'PASS present_npx_path beat_ok' "$OUT/red.log"; then
  cat "$OUT/red.log"
  echo "FAIL: RED must not print green PASS" >&2
  exit 1
fi
echo "OK npx_path RED"

# GREEN
"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_path_tb \
  -GPX_PER_CLK=4 -GRED_DROP_READ=0 \
  -Mdir "$OUT/green" "${SRCS[@]}" >/dev/null
set +e
"$OUT/green/Vpresent_npx_path_tb" >"$OUT/green.log" 2>&1
grc=$?
set -e
grep -q 'PASS present_npx_path beat_ok' "$OUT/green.log" || {
  cat "$OUT/green.log"
  echo "FAIL: green beat conservation" >&2
  exit 1
}
if grep -q '^FAIL ' "$OUT/green.log"; then
  cat "$OUT/green.log"
  echo "FAIL: green log has FAIL" >&2
  exit 1
fi
echo "OK npx_path GREEN rc=$grc"
echo "PASS test_present_npx_path_verilator"
