#!/usr/bin/env bash
# L4 beam geometry RTL sim — product QSF untouched; L4 constants forced in TB.
# Positive: H=1312 V=762 DE=1280x720.
# Negative twins (must fail): wrong-H_TOTAL, off-by-one H_DE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "RTL SIM ERROR: Verilator not found; refusing SKIP-as-pass" >&2
  exit 3
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BEAM_RTL="$ROOT/fpga/Plex_MiSTer/rtl/present_beam_content_de.sv"
TOP="$ROOT/tests/rtl/present_l4_beam_tb_top.sv"
TB="$ROOT/tests/rtl/present_l4_beam_tb.cpp"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
# Product constants checked via dual-header (not product present_core in verilator filelist).
LAYOUT_SVH="$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh"

for f in "$BEAM_RTL" "$TOP" "$TB" "$QIP" "$LAYOUT_SVH"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/present_beam_content_de.sv' "$QIP"; then
  echo "RTL SIM ERROR: present_beam_content_de not in files.qip" >&2
  exit 2
fi
# Product default must stay off (gate does not enable QSF).
if grep -E '^[^#]*PLEX_PRESENT_720P_L4=1' "$ROOT/fpga/Plex_MiSTer/Plex.qsf" >/dev/null; then
  echo "RTL SIM ERROR: product QSF has PLEX_PRESENT_720P_L4 active — default-off violated" >&2
  exit 2
fi
if ! grep -q 'DDR_FRAME_720P24_BEAM_H_TOTAL = 1312' "$LAYOUT_SVH" \
  || ! grep -q 'DDR_FRAME_720P24_BEAM_V_TOTAL = 762' "$LAYOUT_SVH"; then
  echo "RTL SIM ERROR: dual-header L4 beam constants missing 1312/762" >&2
  exit 2
fi

echo "RTL SIM: using $VERILATOR_VERSION" >&2
BUILD_OK="$ROOT/build/verilator/present_l4_beam"
BUILD_BAD_H="$ROOT/build/verilator/present_l4_beam_bad_htot"
BUILD_BAD_DE="$ROOT/build/verilator/present_l4_beam_bad_hde"
mkdir -p "$BUILD_OK" "$BUILD_BAD_H" "$BUILD_BAD_DE"

build_one() {
  local mdir="$1"; shift
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$mdir" \
    --top-module present_l4_beam_tb_top -Wno-fatal \
    -CFLAGS "-std=c++17 -O2" \
    "$@" \
    "$TOP" "$BEAM_RTL" "$TB"
}

echo "=== POSITIVE: L4 720p24 beam ===" >&2
build_one "$BUILD_OK"
set +e
"$BUILD_OK/Vpresent_l4_beam_tb_top"
POS_RC=$?
set -e
echo "present_l4_beam positive true rc=$POS_RC"
if [[ "$POS_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: positive L4 beam geometry failed" >&2
  exit "$POS_RC"
fi

echo "=== NEGATIVE twin: wrong H_TOTAL=1400 (expect fail) ===" >&2
# Note: H_TOTAL < H_DE+32 is clamped UP to 1312 by the beam — that twin is not a fail.
# Oversized H_TOTAL=1400 is accepted and must disagree with expect 1312.
build_one "$BUILD_BAD_H" -GH_TOTAL=1400
set +e
L4_EXP_HTOT=1312 "$BUILD_BAD_H/Vpresent_l4_beam_tb_top"
BAD_H_RC=$?
set -e
echo "present_l4_beam bad_htot true rc=$BAD_H_RC"
if [[ "$BAD_H_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: wrong-H twin incorrectly PASSed" >&2
  exit 1
fi

echo "=== NEGATIVE twin: off-by-one H_DE=1279 (expect fail) ===" >&2
build_one "$BUILD_BAD_DE" -GH_DE=1279
set +e
L4_EXP_HDE=1280 "$BUILD_BAD_DE/Vpresent_l4_beam_tb_top"
BAD_DE_RC=$?
set -e
echo "present_l4_beam bad_hde true rc=$BAD_DE_RC"
if [[ "$BAD_DE_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: off-by-one DE twin incorrectly PASSed" >&2
  exit 1
fi

echo "PASS present_l4_beam_rtl_sim: positive rc=0, bad_htot rc=$BAD_H_RC, bad_hde rc=$BAD_DE_RC"
exit 0
