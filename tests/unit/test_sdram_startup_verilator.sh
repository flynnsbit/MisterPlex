#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERILATOR_BIN="${VERILATOR:-}"
if [[ -z "$VERILATOR_BIN" ]]; then
  if command -v verilator >/dev/null 2>&1; then
    VERILATOR_BIN="$(command -v verilator)"
  elif [[ -x "$HOME/.local/oss-cad-suite-20260726/bin/verilator" ]]; then
    VERILATOR_BIN="$HOME/.local/oss-cad-suite-20260726/bin/verilator"
  fi
fi

if [[ -z "$VERILATOR_BIN" || ! -x "$VERILATOR_BIN" ]]; then
  echo "SKIP: Verilator not found; SDRAM startup command-bus co-sim was not run." >&2
  echo "SKIP: set VERILATOR=/path/to/verilator or install oss-cad-suite under ~/.local." >&2
  exit 0
fi

OUT="$ROOT/build/verilator_sdram_startup"
mkdir -p "$OUT"

"$VERILATOR_BIN" --version
"$VERILATOR_BIN" -Wno-fatal -Wno-IMPLICITSTATIC -Wno-WIDTHTRUNC --cc --exe --build \
  --top-module sdram_startup_top \
  -Mdir "$OUT" \
  "$ROOT/tests/rtl/sdram_startup_top.sv" \
  "$ROOT/tests/rtl/verilator_altddio_stub.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/sdram.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/sdram_memtest.sv" \
  "$ROOT/tests/rtl/test_sdram_startup.cpp" \
  >/dev/null

set +e
"$OUT/Vsdram_startup_top" --inject-early-read >"$OUT/red.log" 2>&1
red_rc=$?
set -e
if [[ "$red_rc" -eq 0 ]]; then
  cat "$OUT/red.log"
  echo "FAIL: injected early READ did not trip the SDRAM startup monitor" >&2
  exit 1
fi
grep -q 'FAIL: READ before first MODE_REGISTER_SET' "$OUT/red.log" || {
  cat "$OUT/red.log"
  echo "FAIL: red run failed for an unexpected reason" >&2
  exit 1
}
echo "RED OK: injected early READ tripped the startup monitor"
grep 'FAIL: READ before first MODE_REGISTER_SET' "$OUT/red.log"

"$OUT/Vsdram_startup_top" >"$OUT/green.log" 2>&1
cat "$OUT/green.log"
grep -q 'PASS: no ACTIVE/READ/WRITE before first MODE_REGISTER_SET' "$OUT/green.log"
