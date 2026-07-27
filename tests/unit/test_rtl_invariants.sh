#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$ROOT/tests/unit/test_rtl_invariants.py"

FAULT_DIR="$ROOT/build/rtl_invariants_quartus_subset"
mkdir -p "$FAULT_DIR"
BAD_DPB_SV="$FAULT_DIR/h264_dpb_quartus_bad.sv"
BAD_DEBLOCK_SV="$FAULT_DIR/h264_deblock_quartus_bad.sv"
cat >"$BAD_DPB_SV" <<'SV'
module h264_dpb_quartus_bad (
    input wire [7:0] ref_win [0:1],
    output logic [7:0] out
);
function automatic [31:0] pix(input int idx);
    pix = {24'd0, ref_win[idx]};
endfunction
always_comb begin
    out = pix(0)[7:0];
end
endmodule
SV
cat >"$BAD_DEBLOCK_SV" <<'SV'
module h264_deblock_quartus_bad #(
    parameter int MB_COUNT = 1170,
    parameter int FRAME_SLOT_W = 2,
    localparam int MB_AW = (MB_COUNT <= 1) ? 1 : $clog2(MB_COUNT)
) (
    input wire clk,
    output wire [MB_AW-1:0] mb_addr
);
assign mb_addr = '0;
endmodule
SV

if QUARTUS_SV_SUBSET_DISABLE_LOCAL_PROBE=1 \
   MISTER_PREFIT_SSH_BIN="$ROOT/build/definitely-missing-ssh" \
   python3 "$ROOT/scripts/check_quartus_sv_subset.py" "$BAD_DPB_SV" >/dev/null 2>"$FAULT_DIR/missing_tool.err"; then
  echo "FAIL: Quartus SV subset guard passed with no reachable Quartus toolchain" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 4 ]] || ! grep -q "QUARTUS_SV_SUBSET_REFUSED(exit=4)" "$FAULT_DIR/missing_tool.err"; then
    echo "FAIL: Quartus SV subset guard missing-tool path returned rc=$rc, want named refusal rc=4" >&2
    cat "$FAULT_DIR/missing_tool.err" >&2
    exit 1
  fi
fi

if python3 "$ROOT/scripts/check_quartus_sv_subset.py" "$BAD_DPB_SV" "$BAD_DEBLOCK_SV" \
     >"$FAULT_DIR/injected_red.out" 2>"$FAULT_DIR/injected_red.err"; then
  echo "FAIL: Quartus SV subset guard accepted injected Quartus-invalid constructs" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "QUARTUS_SV_SUBSET_REJECTED(exit=1)" "$FAULT_DIR/injected_red.err"; then
    echo "FAIL: Quartus SV subset guard injected fault returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/injected_red.err" >&2
    exit 1
  fi
  grep -q "part-select on a function-call result" "$FAULT_DIR/injected_red.err"
  grep -q "unpacked array element" "$FAULT_DIR/injected_red.err"
  grep -q "localparam in module parameter list" "$FAULT_DIR/injected_red.err"
fi
echo "OK red-check: Quartus SV subset guard rejects injected localparam/function-select/unpacked-concat faults and refuses missing toolchain"

if "$ROOT/scripts/check_define_parity.py" --drop-verilator-macro DDR_FRAME_STORE \
     >"$FAULT_DIR/define_parity_red.out" 2>"$FAULT_DIR/define_parity_red.err"; then
  echo "FAIL: define parity guard accepted Verilator/lint without DDR_FRAME_STORE" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "DDR_FRAME_STORE: set by Quartus" "$FAULT_DIR/define_parity_red.err"; then
    echo "FAIL: define parity missing-DDR_FRAME_STORE red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/define_parity_red.err" >&2
    exit 1
  fi
fi
echo "OK red-check: define parity guard rejects missing shared DDR_FRAME_STORE"
