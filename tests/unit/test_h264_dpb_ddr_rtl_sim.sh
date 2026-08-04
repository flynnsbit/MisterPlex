#!/usr/bin/env bash
# DPB DDR path + nb-cache + burst-boundary NEG (w-fitgate).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

echo "=== test_h264_dpb_ddr_rtl_sim EXECUTED ==="

set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP-NOT-PASS: Verilator missing; soft-skip≠PASS" >&2
  exit 77
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL_NB="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_nb_cache.sv"
RTL_BE="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ddr_backend.sv"
RTL_PARAMS="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb_ddr_params.svh"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_dpb_ddr_tb_top.sv"
TB="$ROOT/tests/rtl/h264_dpb_ddr_tb.cpp"
BUILD="$ROOT/build/verilator/h264_dpb_ddr"

for f in "$RTL_NB" "$RTL_BE" "$RTL_PARAMS" "$QIP" "$TOP" "$TB"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_dpb_nb_cache.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip missing h264_dpb_nb_cache.sv" >&2
  exit 2
fi
if ! grep -q 'rtl/h264_dpb_ddr_backend.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip missing h264_dpb_ddr_backend.sv" >&2
  exit 2
fi
# Params .svh must be consumed via `include (not dead QIP-only)
if ! grep -q 'h264_dpb_ddr_params.svh' "$RTL_BE"; then
  echo "RTL SIM ERROR: backend does not include h264_dpb_ddr_params.svh" >&2
  exit 2
fi

mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION"
"$RUN_VERILATOR" --cc --exe --build -sv \
  --Mdir "$BUILD" \
  --top-module h264_dpb_ddr_tb_top -Wno-fatal \
  -I"$ROOT/fpga/Plex_MiSTer/rtl" \
  "$TOP" "$RTL_NB" "$RTL_BE" "$TB"

set +e
"$BUILD/Vh264_dpb_ddr_tb_top"
RC=$?
set -e
echo "h264_dpb_ddr_tb true rc=$RC"
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL h264_dpb_ddr RTL sim" >&2
  exit "$RC"
fi
echo "OK h264_dpb_ddr: area budget + local identity + DDR multi-cy + left-edge NEG + burst NEG"
exit 0
