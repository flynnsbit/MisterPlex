#!/usr/bin/env bash
# Proves the two independent quarter-pel luma implementations in the product
# tree compute the same function.
#
#   h264_luma_qpel_sample       fpga/Plex_MiSTer/rtl/h264_inter_pred.sv
#   h264_luma_qpel_block_16x16  fpga/Plex_MiSTer/rtl/h264_dpb.sv
#
# h264_decode_core used the sample module until w-swap-o5-mc (4f4312b) and uses
# the block module now.  The block module reimplements the 6-tap FIR locally
# instead of instantiating the sample module, so without this gate nothing in
# the tree would notice the two diverging.  That is precisely the failure mode
# that DECODE_REAL_INTRA produced: two configurations, each holding half a
# decoder, every unit test green.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_VERILATOR="$ROOT/scripts/run_verilator.sh"

set +e
VERILATOR_VERSION="$("$RUN_VERILATOR" --version 2>&1)"
VERILATOR_RC=$?
set -e
if [[ "$VERILATOR_RC" -eq 127 ]]; then
  cat >&2 <<SKIP
SKIP RTL SIM: Verilator not found; quarter-pel equivalence was NOT run.
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

RTL_INTER="$ROOT/fpga/Plex_MiSTer/rtl/h264_inter_pred.sv"
RTL_DPB="$ROOT/fpga/Plex_MiSTer/rtl/h264_dpb.sv"
TOP="$ROOT/tests/rtl/qpel_equivalence_tb_top.sv"
TB="$ROOT/tests/rtl/qpel_equivalence_tb.cpp"

build_one() {
  local name="$1"
  local extra_define="$2"
  local build_dir="$ROOT/build/verilator/$name"
  mkdir -p "$build_dir"
  echo "RTL SIM: using $VERILATOR_VERSION ($name)" >&2
  "$RUN_VERILATOR" --cc --exe --build \
    --Mdir "$build_dir" \
    --top-module qpel_equivalence_tb_top -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -CFLAGS "-std=c++17 -O2" \
    $extra_define \
    "$RTL_INTER" "$RTL_DPB" "$TOP" "$TB"
}

# RED first: perturbing one implementation by a single LSB must fail the gate.
build_one qpel_equivalence_neg -DQPEL_EQUIV_NEGATIVE_TEST
NEG_EXE="$ROOT/build/verilator/qpel_equivalence_neg/Vqpel_equivalence_tb_top"
mkdir -p "$ROOT/build"
set +e
"$NEG_EXE" > "$ROOT/build/qpel_equivalence_negative.log" 2>&1
NEG_RC=$?
set -e
if [[ "$NEG_RC" -eq 0 ]]; then
  echo "RTL SIM ERROR: QPEL_EQUIV_NEGATIVE_TEST unexpectedly passed; the gate does not actually compare." >&2
  cat "$ROOT/build/qpel_equivalence_negative.log" >&2
  exit 1
fi
# Machine-check the red against tests/expected_red_manifest.json so the red
# proof cannot silently degrade into "some non-zero exit code".
python3 "$ROOT/tests/unit/expected_red.py" qpel_block_vs_sample_equivalence "$NEG_RC" \
  < "$ROOT/build/qpel_equivalence_negative.log"
sed -n '1,3p' "$ROOT/build/qpel_equivalence_negative.log" >&2

build_one qpel_equivalence_pos ''
POS_EXE="$ROOT/build/verilator/qpel_equivalence_pos/Vqpel_equivalence_tb_top"
"$POS_EXE"
