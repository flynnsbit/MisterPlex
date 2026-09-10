#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOCK_DEFINES=()
case "${CLOCK_PROFILE:?Select control20 or sys120 explicitly}" in
  control20) DIVISOR=1 ;;
  sys120) DIVISOR=6; CLOCK_DEFINES=(-DPLEX_CLK_SYS_120=1) ;;
  *) printf 'Unsupported clock profile\n' >&2; exit 2 ;;
esac
if ps -eo comm= | grep -qE '^quartus_(fit|map|sta|sh)$'; then exit 75; fi
OUT="$ROOT/build/verilator/playback_overlay_$CLOCK_PROFILE"
mkdir -p "$OUT/compiler-scratch"
export TMPDIR="$OUT/compiler-scratch"
sha256sum "$0" "$ROOT/scripts/run_verilator.sh" \
  "$ROOT/fpga/Plex_MiSTer/rtl/playback_overlay_plane.sv" \
  "$ROOT/tests/rtl/playback_overlay_plane_tb.cpp" "$ROOT/tests/frozen-overlay/"*.hpp > "$OUT/inputs.sha256"
bash "$ROOT/scripts/run_verilator.sh" --cc --exe --build -j 1 \
  --Mdir "$OUT" --top-module playback_overlay_plane -Wno-fatal \
  "${CLOCK_DEFINES[@]}" \
  -CFLAGS "-std=c++17 -O2 -DOVERLAY_NATIVE_DIVISOR=$DIVISOR -I$ROOT/tests/frozen-overlay" \
  "$ROOT/fpga/Plex_MiSTer/rtl/playback_overlay_plane.sv" \
  "$ROOT/tests/rtl/playback_overlay_plane_tb.cpp" > "$OUT/build.log" 2>&1
"$OUT/Vplayback_overlay_plane" > "$OUT/execution.log" 2>&1 || { tail -30 "$OUT/execution.log"; exit 1; }
sha256sum --check --status "$OUT/inputs.sha256"
sha256sum "$OUT/Vplayback_overlay_plane" > "$OUT/binary.sha256"
tail -1 "$OUT/execution.log"
