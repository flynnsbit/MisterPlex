#!/usr/bin/env bash
# Prove h264_recon_export carries DPB-committed bytes bit-identically and that
# PLXO ready/torn/bank handshake fails closed (mutation twin FAULT_EARLY_READY).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  echo "SKIP RTL SIM: Verilator not found; h264_recon_export was NOT run." >&2
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing PASS without simulation." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_recon_export.sv"
TOP="$ROOT/tests/rtl/h264_recon_export_tb_top.sv"
TB="$ROOT/tests/rtl/h264_recon_export_tb.cpp"
GOLDEN="$ROOT/tests/fixtures/p3_frame_planes/plex_inter_p16_320x240_12f_i420.yuv"
BUILD="$ROOT/build/verilator/h264_recon_export"
BUILD_FAULT="$ROOT/build/verilator/h264_recon_export_fault"

for f in "$QIP" "$RTL" "$TOP" "$TB" "$GOLDEN"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_recon_export.sv' "$QIP"; then
  echo "FAIL recon_export: files.qip missing h264_recon_export.sv" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION (h264_recon_export)" >&2

# Pre-register (see tb.cpp): bit-identical real-decoded prefix; mid-fill !ready-on-wr;
# abort fail-closed; bank alternation. Mutation FAULT_EARLY_READY must RED.
"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD" \
  --top-module h264_recon_export_tb_top -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"

"$BUILD/Vh264_recon_export_tb_top" --golden "$GOLDEN"

"$RUN_VERILATOR" --cc --exe --build \
  --Mdir "$BUILD_FAULT" \
  --top-module h264_recon_export_tb_top -GFAULT_EARLY_READY=1 -Wno-fatal \
  -CFLAGS "-std=c++17 -O2" \
  "$TOP" "$RTL" "$TB"

set +e
FAULT_OUT="$("$BUILD_FAULT/Vh264_recon_export_tb_top" --golden "$GOLDEN" 2>&1)"
FAULT_RC=$?
set -e
printf '%s\n' "$FAULT_OUT"
if [[ "$FAULT_RC" -eq 0 ]]; then
  echo "FAIL recon_export mutation: FAULT_EARLY_READY unexpectedly passed" >&2
  exit 1
fi
grep -q 'mid-fill PLXO ready on wr bank' <<<"$FAULT_OUT"
echo "OK recon_export mutation twin: FAULT_EARLY_READY went red rc=$FAULT_RC"
