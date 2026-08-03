#!/usr/bin/env bash
# Full-raster no-gap + RED underrun for wide-group present_npx_path.
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

OUT="$ROOT/build/verilator/present_npx_full_raster"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/tests/rtl/present_npx_full_raster_tb.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/present_npx_path.sv"
  "$ROOT/fpga/Plex_MiSTer/rtl/async_fifo.sv"
)

echo "RTL SIM: $($RUN_VERILATOR --version 2>&1 | head -1)"

run_one() {
  local name="$1"
  local gflag="$2"
  local pass_pat="$3"
  rm -rf "$OUT/$name"
  "$RUN_VERILATOR" -Wno-fatal --binary --timing --top-module present_npx_full_raster_tb \
    $gflag -Mdir "$OUT/$name" "${SRCS[@]}" >/dev/null
  set +e
  "$OUT/$name/Vpresent_npx_full_raster_tb" >"$OUT/$name.log" 2>&1
  local rc=$?
  set -e
  grep -q "$pass_pat" "$OUT/$name.log" || {
    cat "$OUT/$name.log"
    echo "FAIL $name missing '$pass_pat' rc=$rc" >&2
    exit 1
  }
  echo "OK $name rc=$rc"
}

run_one green "" "PASS present_npx_full_raster pixels="
run_one red "-GRED_STARVE=1" "PASS present_npx_full_raster RED"

echo "PASS test_present_npx_full_raster"
exit 0
