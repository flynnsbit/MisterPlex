#!/usr/bin/env bash
# Full-frame product deblocking filter gate (W-DEBLOCK-O5).
#
# This gate exists because the previous strongest deblock evidence had a
# 2-macroblock denominator while a real P frame is 1170 macroblocks, and
# because no deblock *filtering* arithmetic was reachable from the product
# decode core at all: only the writeback bookkeeping controller was.
#
# Scope claimed here: every macroblock of a real 624x480 P frame, including
# every P_Skip macroblock, luma and chroma, filtered by product RTL and
# compared bit-exact against an independent frame-level clause 8.7 model.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"
set +e
VERILATOR_VERSION="$($RUN_VERILATOR --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; h264_deblock_mb_filter full-frame simulation was NOT run.
Install oss-cad-suite under ~/.local/oss-cad-suite or run with VERILATOR=/path/to/verilator.
SKIP
  if [[ "${ALLOW_MISSING_VERILATOR:-0}" != "1" ]]; then
    echo "RTL SIM ERROR: Verilator not found; refusing to report PASS without running the simulation." >&2
    echo "A skipped RTL gate is NOT a pass. Set ALLOW_MISSING_VERILATOR=1 only if you accept that RTL was never verified." >&2
    exit 3
  fi
  exit 0
elif [[ "$VERILATOR_RC" -ne 0 ]]; then
  echo "RTL SIM ERROR: Verilator probe failed:" >&2
  printf '%s\n' "$VERILATOR_VERSION" >&2
  exit "$VERILATOR_RC"
fi

RTL="$ROOT/fpga/Plex_MiSTer/rtl/h264_deblock.sv"
QIP="$ROOT/fpga/Plex_MiSTer/files.qip"
TOP="$ROOT/tests/rtl/h264_deblock_mb_tb_top.sv"
TB="$ROOT/tests/rtl/h264_deblock_mb_tb.cpp"
REF="$ROOT/tests/rtl/h264_deblock_ref.hpp"
SCOPE="$ROOT/tests/rtl/h264_real_p_scope.hpp"
REAL_P_FRAME="$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264"
BUILD="$ROOT/build/verilator/h264_deblock_mb"

for f in "$RTL" "$QIP" "$TOP" "$TB" "$REF" "$SCOPE" "$REAL_P_FRAME"; do
  if [[ ! -f "$f" ]]; then
    echo "RTL SIM ERROR: missing required file: $f" >&2
    exit 2
  fi
done
if ! grep -q 'rtl/h264_deblock.sv' "$QIP"; then
  echo "RTL SIM ERROR: files.qip does not list product h264_deblock.sv" >&2
  exit 2
fi

# The product claim is not "a module exists in a file" but "the filter is
# reachable from the chosen product decode lineage".  Plain emu-rooted
# reachability is masked by the retired decode_stub painter, so root at the
# decode core -- but w-audit proved a core-subtree green can co-exist with a
# core that `emu` cannot reach at all.  A subtree proof without a trunk proof
# is vacuous, so run both directions plus the files.qip cross-check and let the
# helper print which of PRODUCT_REACHABLE / CORE_SUBTREE_ONLY actually holds.
REACH_ARGS=(
  --label h264_deblock_mb_full_frame
  --require h264_deblock_mb_filter
  --require h264_deblock_edge_pipe
  --require h264_deblock_edge
  --require h264_deblock_thresholds
  --require h264_deblock_bs
  --require h264_deblock_qpc
  --require h264_deblock_writeback_ctrl
)
python3 "$ROOT/scripts/check_product_reachability.py" "${REACH_ARGS[@]}"

mkdir -p "$BUILD"
echo "RTL SIM: using $VERILATOR_VERSION" >&2
build_variant() {
  local dir="$1"; shift
  mkdir -p "$dir"
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$dir" \
    --top-module h264_deblock_mb_tb_top -Wno-fatal "$@" \
    -CFLAGS "-std=c++17 -O2 -I$ROOT -I$ROOT/host -I$ROOT/tests/rtl" \
    "$TOP" "$RTL" "$TB"
}

build_variant "$BUILD"
"$BUILD/Vh264_deblock_mb_tb_top" "$REAL_P_FRAME"

# ── Reference-side red checks ───────────────────────────────────────────────
# Each mutates the *reference* away from the standard.  If the RTL really
# implements that part of the standard, the bit-exact comparison must fail.
ref_red() {
  local mode="$1" label="$2"
  set +e
  local out rc
  out="$(DEBLOCK_MB_MODE="$mode" "$BUILD/Vh264_deblock_mb_tb_top" "$REAL_P_FRAME" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL h264_deblock_mb_filter red-check: $label unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -q 'FAIL h264_deblock_mb_filter' <<<"$out"; then
    echo "FAIL h264_deblock_mb_filter red-check: $label produced no filter diagnostic" >&2
    exit 1
  fi
  echo "OK h264_deblock_mb_filter red-check: $label changed the picture"
}

ref_red ref_no_chroma        "chroma edges dropped from the reference"
ref_red ref_qpy_for_qpc      "QPy substituted for QPc in the reference"
ref_red ref_horiz_first      "horizontal edges filtered before vertical in the reference"
ref_red ref_skip_skipped     "P_Skip macroblocks left unfiltered in the reference"
ref_red ref_mb_edges_only    "internal 4x4 edges dropped from the reference"
ref_red harness_skip_skipped "P_Skip macroblocks never driven into the RTL"

# ── RTL-side red checks ─────────────────────────────────────────────────────
# These are the ones that matter for regression: they mutate the *product RTL*
# and must be caught by the same full-frame comparison.
rtl_red() {
  local define="$1" label="$2"
  local dir="$ROOT/build/verilator/h264_deblock_mb_fault_$(tr 'A-Z' 'a-z' <<<"${define##H264_DEBLOCK_MB_FAULT_}")"
  build_variant "$dir" "+define+$define"
  set +e
  local out rc
  out="$("$dir/Vh264_deblock_mb_tb_top" "$REAL_P_FRAME" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "$out"
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL h264_deblock_mb_filter RTL red-check: $label unexpectedly passed" >&2
    exit 1
  fi
  if ! grep -q 'FAIL h264_deblock_mb_filter' <<<"$out"; then
    echo "FAIL h264_deblock_mb_filter RTL red-check: $label produced no filter diagnostic" >&2
    exit 1
  fi
  echo "OK h264_deblock_mb_filter RTL red-check: $label failed the full-frame comparison"
}

rtl_red H264_DEBLOCK_MB_FAULT_DROP_CHROMA  "product RTL stops filtering chroma"
rtl_red H264_DEBLOCK_MB_FAULT_QPY_FOR_QPC  "product RTL uses QPy on chroma edges"
rtl_red H264_DEBLOCK_MB_FAULT_MB_EDGE_ONLY "product RTL stops filtering internal 4x4 edges"
rtl_red H264_DEBLOCK_MB_FAULT_HORIZ_FIRST  "product RTL filters horizontal edges first"

echo "OK h264_deblock_mb_filter: full-frame product deblocking gate green with red proofs"
