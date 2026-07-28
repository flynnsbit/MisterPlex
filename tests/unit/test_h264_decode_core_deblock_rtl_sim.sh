#!/usr/bin/env bash
# In-loop deblocking gate for h264_decode_core (W-DEBLOCK-O5).
#
# Before this gate existed, no deblock *filtering* arithmetic was reachable
# from h264_decode_core at all: only h264_deblock_writeback_ctrl, which counts
# samples and orders commits.  The core wrote reconstructed samples straight to
# the DPB and merely labelled them "filtered", so the PRE/POST separation
# contract was physically vacuous.
#
# Scope claimed here: 1170 macroblocks (39x30, 624x480) driven through the
# product core with DEBLOCK_IN_LOOP=1, all 449280 DPB sample writes captured.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_decode_core in-loop deblock simulation was NOT run.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    echo "A skipped RTL gate is NOT a pass." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_decode_core.sv"
CAVLC_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_cavlc_residual.sv"
IQ_IDCT_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv"
DPB_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
INTER_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv"
DEBLOCK_RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_decode_core_deblock_tb.sv"
TB="$ROOT/tests/rtl/h264_decode_core_deblock_tb.cpp"
REF="$ROOT/tests/rtl/h264_deblock_ref.hpp"
BUILD="$ROOT/build/verilator/h264_decode_core_deblock"

for f in "$RTL" "$CAVLC_RTL" "$IQ_IDCT_RTL" "$DPB_RTL" "$INTER_RTL" "$DEBLOCK_RTL" "$QIP" "$TOP" "$TB" "$REF"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_decode_core.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_decode_core.sv" >&2
  exit 2
fi
if ! grep -q 'rtl/h264_deblock.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list h264_deblock.sv" >&2
  exit 2
fi

# Product-lineage reachability.  Plain emu-rooted reachability is masked by the
# retired decode_stub painter, so root at the decode core.  This is necessary,
# not sufficient -- the simulation below is what proves the filter does work.
python3 "$ROOT/scripts/check_rtl_module_instantiations.py" --root h264_decode_core \
  --require h264_deblock_mb_filter \
  --require h264_deblock_edge_pipe \
  --require h264_deblock_edge \
  --require h264_deblock_thresholds \
  --require h264_deblock_bs \
  --require h264_deblock_qpc \
  --require h264_deblock_writeback_ctrl

echo "RTL SIM: using $VERILATOR_VERSION (h264_decode_core in-loop deblock)" >&2
build_variant() {
  local dir="$1"; shift
  mkdir -p "$dir"
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$dir" \
    --top-module h264_decode_core_deblock_tb -Wno-fatal "$@" \
    -CFLAGS "-std=c++17 -O2 -I$ROOT/tests/rtl" \
    "$TOP" "$CAVLC_RTL" "$IQ_IDCT_RTL" "$INTER_RTL" "$DPB_RTL" "$DEBLOCK_RTL" "$RTL" "$TB"
}

build_variant "$BUILD"
"$BUILD/Vh264_decode_core_deblock_tb"

rtl_red() {
  local define="$1" label="$2" want="$3"
  local dir="$ROOT/build/verilator/h264_decode_core_deblock_fault_$(tr 'A-Z' 'a-z' <<<"$define")"
  build_variant "$dir" "+define+$define"
  set +e
  local out rc
  out="$("$dir/Vh264_decode_core_deblock_tb" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL h264_decode_core deblock red-check: $label unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -q "$want" <<<"$out"; then
    echo "FAIL h264_decode_core deblock red-check: $label did not produce the expected diagnostic ($want)" >&2
    exit 1
  fi
  echo "OK h264_decode_core deblock red-check: $label was caught"
}

# The DPB must see POST-deblock samples.
rtl_red H264_DECODE_CORE_FAULT_PRE_DEBLOCK_TO_DPB \
  "core routes PRE-deblock samples to the DPB" \
  "FAIL h264_decode_core deblock"
# Chroma must be filtered on the core path, not just luma.
rtl_red H264_DEBLOCK_MB_FAULT_DROP_CHROMA \
  "filter stops touching chroma" \
  "chroma deblocking is not on the core writeback path"
# QPc must be used on chroma edges, not QPy.
rtl_red H264_DEBLOCK_MB_FAULT_QPY_FOR_QPC \
  "filter uses QPy on chroma edges" \
  "want QPc"
# DPB promotion must stay behind the frame boundary.
rtl_red H264_DEBLOCK_FAULT_REF_READY_EARLY \
  "reference promoted before the frame boundary" \
  "ordering"
# A macroblock must not commit before its 384 filtered samples have gone by.
rtl_red H264_DECODE_CORE_FAULT_COMMIT_BEFORE_SAMPLES \
  "macroblock committed before its filtered sample run finished" \
  "FAIL h264_decode_core deblock"

echo "OK h264_decode_core deblock: in-loop deblocking gate green with red proofs"
