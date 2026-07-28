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

# Product-lineage reachability, both directions.  Plain emu-rooted reachability
# is masked by the retired decode_stub painter, so the subtree is rooted at the
# decode core -- but w-audit proved a core-subtree green can co-exist with a
# core `emu` cannot reach at all, so the trunk proof and the files.qip
# cross-check run too.  All of this is necessary, not sufficient: the
# elaboration + simulation below is what proves the filter does work, and is
# the part immune to the checker's source-level blind spots (a filter hidden in
# a disabled generate would elaborate away and the sample counters would
# collapse to zero).
python3 "$ROOT/scripts/check_product_reachability.py" \
  --label h264_decode_core_deblock \
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

# ── w-audit blind-spot regression: disabled generate ────────────────────────
# w-audit measured that check_rtl_module_instantiations.py reports an
# instantiation inside a disabled `if (0)` generate as REACHABLE.  A module can
# therefore pass every source-level reachability check while elaborating away
# to nothing.  Elaboration + simulation is immune to that, and this case exists
# to keep it that way: hide the filter behind `if (1'b0)` and the gate must go
# red even though the source graph stays green.
DG_BACKUP="$ROOT/build/w-deblock-o5-core-disabled-generate.orig.sv"
mkdir -p "$ROOT/build"
cat "$RTL" > "$DG_BACKUP"
restore_core() { cat "$DG_BACKUP" > "$RTL"; }
trap restore_core EXIT

python3 - "$RTL" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
head = "    h264_deblock_mb_filter u_core_deblock_mb ("
i = text.index(head)
j = text.index(");", text.index(".unsupported_ref", i)) + 2
inst = text[i:j]
open(path, "w").write(
    text[:i] + "    generate if (1'b0) begin : g_dead_deblock\n" + inst
    + "\n    end endgenerate\n" + text[j:])
PY

set +e
python3 "$ROOT/scripts/check_product_reachability.py" --label disabled_generate_probe \
  --require h264_deblock_mb_filter > "$ROOT/build/w-deblock-o5-disabled-generate-checker.log" 2>&1
DG_CHECKER_RC=$?
set -e
# Recorded, deliberately not asserted: if w-gate-o5 teaches the checker about
# disabled generates this should flip to non-zero, and that is an improvement,
# not a regression of this gate.
echo "NOTE disabled-generate: source-level check_product_reachability rc=$DG_CHECKER_RC (0 = w-audit's documented false green)"

DG_DIR="$ROOT/build/verilator/h264_decode_core_deblock_disabled_generate"
set +e
build_variant "$DG_DIR" > "$ROOT/build/w-deblock-o5-disabled-generate-build.log" 2>&1
DG_BUILD_RC=$?
DG_OUT=""
DG_RUN_RC=0
if [[ "$DG_BUILD_RC" -eq 0 ]]; then
  DG_OUT="$("$DG_DIR/Vh264_decode_core_deblock_tb" 2>&1)"
  DG_RUN_RC=$?
else
  DG_RUN_RC=$DG_BUILD_RC
fi
set -e
restore_core
trap - EXIT
if ! git -C "$ROOT" diff --quiet -- "$RTL"; then
  echo "FAIL h264_decode_core deblock red-check: disabled-generate mutation was not restored" >&2
  exit 1
fi
printf '%s\n' "$DG_OUT"
if [[ "$DG_RUN_RC" -eq 0 ]]; then
  echo "FAIL h264_decode_core deblock red-check: filter hidden in a disabled generate still passed;" >&2
  echo "  elaboration is no longer catching what the source checker cannot see." >&2
  exit 1
fi
echo "OK h264_decode_core deblock red-check: filter hidden in a disabled generate was caught by elaboration (sim rc=$DG_RUN_RC) while the source graph stayed rc=$DG_CHECKER_RC"

echo "OK h264_decode_core deblock: in-loop deblocking gate green with red proofs"
