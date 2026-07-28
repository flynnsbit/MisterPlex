#!/usr/bin/env bash
# RTL-in-the-loop reconstruction scorer.
#
# Runs the real RTL dequant/IDCT/recon pipeline over ALL luma blocks of ALL MBs
# of the fixture and compares bit-exactly against an ffmpeg-derived golden,
# with a RED-check (a single coefficient +1 must fail).
#
# PROVENANCE: extracted verbatim from tests/unit/test_stream_path_full_frame_compare.sh
# by w-decode-o5 when decode_stub's on-chip DPB was removed.  That test's OTHER
# half measured inter prediction by poking decode_stub's private dpb_mem array,
# which was 1.30x the device's total block RAM and could not exist in silicon;
# it has been retired (see fpga/Plex_MiSTer/rtl/retired_measurements.txt).
#
# This half never touched decode_stub or stream_path: it builds its own top
# module h264_rtl_recon_scorer_tb against h264_iq_idct_4x4.sv directly.  It is
# split out so that retiring the stub DPB does not silently drop 76,800 luma
# pixels of genuine RTL coverage.
#
# SCOPE, stated honestly: this is module-level injection (golden -> RTL ->
# compare) of the dequant/IDCT/recon arithmetic.  It is NOT a connected
# pipeline and it is NOT evidence that the FPGA decodes or displays anything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; RTL recon scorer was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  if [[ "${REQUIRE_RTL_SIM:-0}" == "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    exit 3
  fi
  exit 77
fi
if [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: verilator --version failed rc=$VERILATOR_RC: $VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

BITSTREAM="${FULL_FRAME_BITSTREAM:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264}"
REF_DIR="$ROOT/build/p3_full_frame"

if [ ! -f "$BITSTREAM" ]; then
  echo "RTL SIM ERROR: fixture bitstream not found: $BITSTREAM" >&2
  exit 2
fi
if [ ! -x "$ROOT/build/extract_h264_golden" ]; then
  echo "RTL SIM ERROR: build/extract_h264_golden not built; run 'make unit' prerequisites first" >&2
  exit 2
fi

RTL_SCORER_BUILD="$ROOT/build/verilator/rtl_recon_scorer"
RTL_GOLDEN_DIR="$REF_DIR/goldens_all_mbs"
mkdir -p "$RTL_SCORER_BUILD" "$RTL_GOLDEN_DIR"
"$RUN_VERILATOR" --cc --exe --build \
  -Mdir "$RTL_SCORER_BUILD" \
  --top-module h264_rtl_recon_scorer_tb \
  -Wno-fatal \
  "$ROOT/tests/rtl/h264_rtl_recon_scorer_tb.sv" \
  "$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv" \
  "$ROOT/tests/rtl/h264_rtl_recon_scorer_tb.cpp"

if [ ! -f "$RTL_GOLDEN_DIR/mb_000.json" ] || \
   [ "$BITSTREAM" -nt "$RTL_GOLDEN_DIR/mb_000.json" ]; then
  "$ROOT/build/extract_h264_golden" --input "$BITSTREAM" --all-mbs --output-dir "$RTL_GOLDEN_DIR"
fi

"$RTL_SCORER_BUILD/Vh264_rtl_recon_scorer_tb" --dir "$RTL_GOLDEN_DIR" --red-check
