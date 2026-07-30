#!/usr/bin/env bash
# Prove h264_recon_export packing + handshake; mutation twins go RED.
# Scope: MB-scale packing (384 B), not full-frame product DPB quality.
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
# Stride must fit 624x480 I420 (449280); 0x40000 does not.
# Do not name unrelated product .sv paths here — test_bench_rtl_filelists treats
# bare *.sv mentions as Verilator inputs (MODMISSING false positive).
if grep -nE "BANK_STRIDE = 32'h0004_0000|BANK_STRIDE\\(32'h0004_0000\\)|kReconExportBankStride = 0x00040000" \
    "$RTL" "$TOP" "$ROOT/host/libmisterplex/mailbox_abi_spec.hpp" 2>/dev/null; then
  echo "FAIL recon_export: stale 256 KiB bank stride still present" >&2
  exit 2
fi
_sp="$ROOT/fpga/Plex_MiSTer/rtl/stream_path"
if ! grep -q "BANK_STRIDE(32'h0008_0000)" "${_sp}.sv"; then
  echo "FAIL recon_export: stream_path export instance stride not 512 KiB" >&2
  exit 2
fi
if ! grep -q 'sample_count' "$RTL"; then
  echo "FAIL recon_export: completeness sample_count missing" >&2
  exit 2
fi
if ! grep -q 'pending_start\|start_ready' "$RTL"; then
  echo "FAIL recon_export: idle/pending frame_start guard missing" >&2
  exit 2
fi
if ! grep -q 'plxoPostCopyStable' "$ROOT/host/libmisterplex/mailbox_abi_spec.hpp"; then
  echo "FAIL recon_export: ARM post-copy PLXO helper missing" >&2
  exit 2
fi
if ! grep -q 'PLXO changed during copy' "$ROOT/arm/misterplexd/fpga_spi.cpp"; then
  echo "FAIL recon_export: ARM post-copy PLXO re-read missing" >&2
  exit 2
fi

mkdir -p "$BUILD" "$BUILD_FAULT"
echo "RTL SIM: using $VERILATOR_VERSION (h264_recon_export)" >&2

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
