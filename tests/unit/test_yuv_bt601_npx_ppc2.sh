#!/usr/bin/env bash
# Odd/even distinct-pixel checksum for PPC=2 N-wide extract (rd-duck gate).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
OSS_CAD_SUITE="${OSS_CAD_SUITE:-$HOME/.local/oss-cad-suite-20260726}"
BUILD="$ROOT/build/verilator/yuv_bt601_npx_ppc2"
mkdir -p "$BUILD"

set +e
VERILATOR_VERSION="$(OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed rc=$VERILATOR_RC" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi
echo "RTL SIM: using $VERILATOR_VERSION (yuv_bt601_npx_ppc2)" >&2

OSS_CAD_SUITE="$OSS_CAD_SUITE" "$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module yuv_bt601_npx_ppc2_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  -CFLAGS "-std=c++17" \
  "$ROOT/tests/rtl/yuv_bt601_npx_ppc2_tb_top.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/yuv_bt601_npx.sv" \
  "$ROOT/tests/rtl/yuv_bt601_npx_ppc2_tb.cpp"

"$BUILD/Vyuv_bt601_npx_ppc2_tb_top"
rc=$?
echo "yuv_bt601_npx_ppc2 sim rc=$rc"
exit "$rc"
