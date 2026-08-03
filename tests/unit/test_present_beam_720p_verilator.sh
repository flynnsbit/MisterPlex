#!/usr/bin/env bash
# present_beam_ppc + present_video_timing_720p: genuine 1280×720 DE @ PPC=2.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
"$RUN_VERILATOR" --version >/dev/null 2>&1
VRC=$?
set -e
if [[ "$VRC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing" >&2
  exit 77
elif [[ "$VRC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed rc=$VRC" >&2
  exit "$VRC"
fi

OUT="$ROOT/build/verilator/present_beam_720p"
mkdir -p "$OUT"
RTL="$ROOT/fpga/Plex_MiSTer/rtl"
SRCS=(
  "$ROOT/tests/rtl/present_beam_720p_tb.sv"
  "$RTL/present_beam_ppc.sv"
  "$RTL/present_video_timing_720p.sv"
)

"$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_beam_720p_tb \
  -GPX_PER_CLK=2 \
  -Mdir "$OUT/green" "${SRCS[@]}" >/dev/null
set +e
"$OUT/green/Vpresent_beam_720p_tb" >"$OUT/green.log" 2>&1
GRC=$?
set -e
grep -q 'PASS present_beam_720p' "$OUT/green.log" || {
  cat "$OUT/green.log"
  echo "FAIL present_beam_720p green" >&2
  exit 1
}
if grep -q '^FAIL ' "$OUT/green.log"; then
  cat "$OUT/green.log"
  exit 1
fi
echo "OK present_beam_720p GREEN rc=$GRC"
echo "true rc=$GRC"
echo "PASS test_present_beam_720p_verilator"
