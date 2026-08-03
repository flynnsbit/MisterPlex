#!/usr/bin/env bash
set -euo pipefail
assert_sim_executed() {
  local label="$1"; shift; local log="$1"; shift; local missing=0 m
  for m in "$@"; do
    grep -q -- "$m" <<<"$log" || { echo "FAIL $label missing $m" >&2; missing=1; }
  done
  [[ "$missing" -eq 0 ]] || { echo "FAIL compile-only" >&2; exit 2; }
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/scripts/run_verilator.sh"
set +e; VER="$($RUN --version 2>&1)"; RC=$?; set -e
if [[ "$RC" -eq 127 ]]; then
  [[ "${ALLOW_MISSING_VERILATOR:-0}" == "1" ]] && exit 77
  exit 3
elif [[ "$RC" -ne 0 ]]; then exit "$RC"; fi
BUILD="$ROOT/build/verilator/plex_chrome_ppc"
mkdir -p "$BUILD"
"$RUN" --cc --exe --build --top-module plex_chrome_ppc_tb \
  -Wno-fatal -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -CFLAGS "-std=c++17 -O2" --Mdir "$BUILD" \
  "$ROOT/tests/rtl/plex_chrome_ppc_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome_host_if.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/plex_chrome.sv" \
  "$ROOT/tests/rtl/plex_chrome_ppc_tb.cpp"
set +e; OUT="$("$BUILD/Vplex_chrome_ppc_tb" 2>&1)"; RC=$?; set -e
printf '%s\n' "$OUT"
echo "plex_chrome_ppc_tb rc=$RC"
assert_sim_executed "ppc" "$OUT" "PASS ppc2-passthrough" "PASS ppc2-lane-split" "PASS ppc2-outside" "plex_chrome_ppc_tb: PASS"
[[ "$RC" -eq 0 ]] || exit "$RC"
echo "test_plex_chrome_ppc_rtl_sim: PASS"
exit 0
