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

run_ppc() {
  local ppc="$1"
  local dir="$OUT/ppc${ppc}"
  mkdir -p "$dir"
  "$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_beam_720p_tb \
    -GPX_PER_CLK="$ppc" \
    -Mdir "$dir" "${SRCS[@]}" >/dev/null
  set +e
  "$dir/Vpresent_beam_720p_tb" >"$dir/log.txt" 2>&1
  local rc=$?
  set -e
  grep -q 'PASS present_beam_720p' "$dir/log.txt" || {
    cat "$dir/log.txt"
    echo "FAIL present_beam_720p ppc=$ppc" >&2
    exit 1
  }
  if grep -q '^FAIL ' "$dir/log.txt"; then
    cat "$dir/log.txt"
    exit 1
  fi
  echo "OK present_beam_720p ppc=$ppc GREEN rc=$rc"
  echo "true rc=$rc"
}

run_ppc 2
run_ppc 4
echo "PASS test_present_beam_720p_verilator"
