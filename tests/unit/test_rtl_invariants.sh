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

FIT_GREEN="$FAULT_DIR/fake_fit_green.rpt"
FIT_RED="$FAULT_DIR/fake_fit_red.rpt"
FIT_LOOP_LOG="$FAULT_DIR/fake_fit_loop.log"
FIT_CFG="$FAULT_DIR/critical_fit_one_module.json"
cat >"$FIT_CFG" <<'JSON'
{
  "schema": "misterplex.critical_fit_hierarchy.v1",
  "modules": [
    {
      "name": "ddr_frame_store",
      "entity": "ddr_frame_store",
      "hierarchy_contains": "ddr_frame_store:fstore",
      "log_contains": "present|fstore",
      "min_comb_aluts": 1000,
      "min_registers": 500,
      "min_block_memory_bits": 100000,
      "min_m10ks": 1
    }
  ]
}
JSON
cat >"$FIT_GREEN" <<'RPT'
; Compilation Hierarchy Node ; ALMs needed [=A-B+C] ; [A] ALMs used in final placement ; [B] Estimate of ALMs recoverable by dense packing ; [C] Estimate of ALMs unavailable ; ALMs used for memory ; Combinational ALUTs ; Dedicated Logic Registers ; I/O Registers ; Block Memory Bits ; M10Ks ; DSP Blocks ; Pins ; Virtual Pins ; Full Hierarchy Name ; Entity Name ; Library Name ;
;          |ddr_frame_store:fstore| ; 2974.3 (2951.7) ; 3416.0 (3386.2) ; 603.6 (595.9) ; 161.9 (161.4) ; 0.0 (0.0) ; 4116 (4085) ; 1828 (1794) ; 0 (0) ; 159744 ; 96 ; 6 ; 0 ; 0 ; |sys_top|emu:emu|present_core:present|ddr_frame_store:fstore ; ddr_frame_store ; work ;
RPT
cat >"$FIT_RED" <<'RPT'
; Compilation Hierarchy Node ; ALMs needed [=A-B+C] ; [A] ALMs used in final placement ; [B] Estimate of ALMs recoverable by dense packing ; [C] Estimate of ALMs unavailable ; ALMs used for memory ; Combinational ALUTs ; Dedicated Logic Registers ; I/O Registers ; Block Memory Bits ; M10Ks ; DSP Blocks ; Pins ; Virtual Pins ; Full Hierarchy Name ; Entity Name ; Library Name ;
;          |ddr_frame_store:fstore| ; 0 ; 0 ; 0 ; 0 ; 0 ; 2 ; 0 ; 0 ; 0 ; 0 ; 0 ; 0 ; 0 ; |sys_top|emu:emu|present_core:present|ddr_frame_store:fstore ; ddr_frame_store ; work ;
RPT
"$ROOT/scripts/check_quartus_fit_hierarchy.py" --fit-rpt "$FIT_GREEN" --config "$FIT_CFG" >/dev/null
if "$ROOT/scripts/check_quartus_fit_hierarchy.py" --fit-rpt "$FIT_RED" --config "$FIT_CFG" \
     >"$FAULT_DIR/fit_hierarchy_red.out" 2>"$FAULT_DIR/fit_hierarchy_red.err"; then
  echo "FAIL: fit hierarchy guard accepted optimized-away ddr_frame_store" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "ddr_frame_store: registers 0 < required 500" "$FAULT_DIR/fit_hierarchy_red.err"; then
    echo "FAIL: fit hierarchy red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/fit_hierarchy_red.err" >&2
    exit 1
  fi
fi
cat >"$FIT_LOOP_LOG" <<'LOG'
Warning (332125): Found combinational loop of 7 nodes File: /build/rtl/async_fifo.sv Line: 34
    Warning (332126): Node "emu|present|fstore|input_fifo|comb~3|combout"
LOG
if "$ROOT/scripts/check_quartus_fit_hierarchy.py" --fit-rpt "$FIT_GREEN" --log "$FIT_LOOP_LOG" --config "$FIT_CFG" \
     >"$FAULT_DIR/fit_loop_red.out" 2>"$FAULT_DIR/fit_loop_red.err"; then
  echo "FAIL: fit hierarchy guard accepted critical-module combinational loop warning" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "critical-module combinational-loop" "$FAULT_DIR/fit_loop_red.err"; then
    echo "FAIL: fit hierarchy comb-loop red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/fit_loop_red.err" >&2
    exit 1
  fi
fi
echo "OK red-check: fit hierarchy guard rejects optimized-away or comb-looped ddr_frame_store"

STA_RED="$FAULT_DIR/fake_timing_red.sta.rpt"
cat >"$STA_RED" <<'RPT'
; Setup Summary ;
; Clock ; Slack ; End Point TNS ;
; clk_ddr ; -0.125 ; -1.250 ;
RPT
if "$ROOT/scripts/check_quartus_timing.py" --sta-rpt "$STA_RED" \
     >"$FAULT_DIR/timing_red.out" 2>"$FAULT_DIR/timing_red.err"; then
  echo "FAIL: timing guard accepted negative setup slack" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "QUARTUS_TIMING_REJECTED(exit=1)" "$FAULT_DIR/timing_red.err"; then
    echo "FAIL: timing red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/timing_red.err" >&2
    exit 1
  fi
fi
echo "OK red-check: timing guard rejects negative slack"

# ── timing-exclusion gate red-checks ──
STA_EXCL_GREEN="$FAULT_DIR/fake_timing_excl_green.sta.rpt"
cat >"$STA_EXCL_GREEN" <<'RPT'
; Setup Summary ;
; Clock ; Slack ; End Point TNS ;
; general[0].gpll ; 0.245 ; 0.000 ;
; general[2].gpll ; 0.100 ; 0.000 ;
;
; Hold Summary ;
; Clock ; Slack ; End Point TNS ;
; general[0].gpll ; 0.125 ; 0.000 ;
; general[2].gpll ; 0.200 ; 0.000 ;
RPT

EXCL_EVIL_SDC="$FAULT_DIR/evil_async.sdc"
cat >"$EXCL_EVIL_SDC" <<'SDC'
set_clock_groups -asynchronous \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|general[0].*|divclk}] \
   -group [get_clocks { *|pll|pll_inst|altera_pll_i|general[2].*|divclk}]
SDC

# Green: existing SDC files only
"$ROOT/scripts/check_timing_exclusions.py" --sta-rpt "$STA_EXCL_GREEN" >/dev/null
echo "OK green: timing exclusion gate passes with baseline SDC and good STA"

# Red: new -asynchronous clock group
if "$ROOT/scripts/check_timing_exclusions.py" \
     --sdc "$ROOT/fpga/Plex_MiSTer/sys/sys_top.sdc" \
     --sdc "$ROOT/fpga/Plex_MiSTer/Plex.sdc" \
     --sdc "$EXCL_EVIL_SDC" \
     --sta-rpt "$STA_EXCL_GREEN" \
     >"$FAULT_DIR/excl_evil.out" 2>"$FAULT_DIR/excl_evil.err"; then
  echo "FAIL: timing exclusion gate accepted new -asynchronous clock group" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "HIGH RISK" "$FAULT_DIR/excl_evil.err"; then
    echo "FAIL: timing exclusion evil-SDC red-check returned rc=$rc, want rejection rc=1 with HIGH RISK" >&2
    cat "$FAULT_DIR/excl_evil.err" >&2
    exit 1
  fi
fi
echo "OK red-check: timing exclusion gate rejects new -asynchronous clock group"

# Red: missing expected clock in STA
STA_MISSING_CLK="$FAULT_DIR/sta_missing_clock.rpt"
cat >"$STA_MISSING_CLK" <<'RPT'
; Setup Summary ;
; Clock ; Slack ; End Point TNS ;
; general[0].gpll ; 0.245 ; 0.000 ;
;
; Hold Summary ;
; Clock ; Slack ; End Point TNS ;
; general[0].gpll ; 0.125 ; 0.000 ;
RPT
if "$ROOT/scripts/check_timing_exclusions.py" --sta-rpt "$STA_MISSING_CLK" \
     >"$FAULT_DIR/excl_missing.out" 2>"$FAULT_DIR/excl_missing.err"; then
  echo "FAIL: timing exclusion gate accepted STA missing general[2].gpll" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "general\[2\].gpll" "$FAULT_DIR/excl_missing.err"; then
    echo "FAIL: timing exclusion missing-clock red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/excl_missing.err" >&2
    exit 1
  fi
fi
echo "OK red-check: timing exclusion gate rejects missing expected clock"

# Red: empty STA (zero analysed rows)
STA_EMPTY="$FAULT_DIR/sta_empty.rpt"
cat >"$STA_EMPTY" <<'RPT'
; Quartus Prime TimeQuest Timing Analyzer Report
RPT
if "$ROOT/scripts/check_timing_exclusions.py" --sta-rpt "$STA_EMPTY" \
     >"$FAULT_DIR/excl_empty.out" 2>"$FAULT_DIR/excl_empty.err"; then
  echo "FAIL: timing exclusion gate accepted empty STA report" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "ZERO analysed" "$FAULT_DIR/excl_empty.err"; then
    echo "FAIL: timing exclusion empty-STA red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$FAULT_DIR/excl_empty.err" >&2
    exit 1
  fi
fi
echo "OK red-check: timing exclusion gate rejects empty STA (zero checked paths)"

# ── instantiated mailbox window red-checks ──
# The gap being closed: the layout .svh and ddr_frame_layout.hpp can agree with
# each other perfectly and still name a doorbell that does not follow the bank
# stride, or present_core can be wired to a different family than the host
# probes. Both produce a core whose mailboxes answer from a stale DDR image
# instead of failing, so each fault below is injected in a way that leaves every
# pre-existing consistency gate satisfied.
WINDOW_DIR="$FAULT_DIR/instantiated_window"
mkdir -p "$WINDOW_DIR"

# Fault 1: stride and doorbell disagree, but the two layout headers agree with
# each other. 0x80000 stride puts the doorbell at 0x300FF000; claim 0x3007F000
# (the 0x40000-stride window) in BOTH headers at once.
sed 's/DDR_FRAME_YUV420P_DOORBELL_PHYS = 32.h300F_F000/DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'"'"'h3007_F000/' \
  "$ROOT/fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh" >"$WINDOW_DIR/layout_bad.svh"
sed 's/kPlex480pYuv420pDoorbellPhys = 0x300FF000/kPlex480pYuv420pDoorbellPhys = 0x3007F000/' \
  "$ROOT/host/libmisterplex/ddr_frame_layout.hpp" >"$WINDOW_DIR/layout_bad.hpp"
if ! grep -q "32'h3007_F000" "$WINDOW_DIR/layout_bad.svh" \
   || ! grep -q "kPlex480pYuv420pDoorbellPhys = 0x3007F000" "$WINDOW_DIR/layout_bad.hpp"; then
  echo "FAIL: instantiated-window fault 1 did not inject; the source spelling changed" >&2
  exit 1
fi
if DDR_FRAME_LAYOUT_SVH="$WINDOW_DIR/layout_bad.svh" \
   DDR_FRAME_LAYOUT_HPP="$WINDOW_DIR/layout_bad.hpp" \
   python3 "$ROOT/tests/unit/test_rtl_invariants.py" \
     >"$WINDOW_DIR/f1.out" 2>"$WINDOW_DIR/f1.err"; then
  echo "FAIL: instantiated-window gate accepted a doorbell that does not follow its bank stride" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "not where a two-bank" "$WINDOW_DIR/f1.out" "$WINDOW_DIR/f1.err"; then
    echo "FAIL: instantiated-window stride/doorbell red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$WINDOW_DIR/f1.out" "$WINDOW_DIR/f1.err" >&2
    exit 1
  fi
fi

# Fault 2: present_core keeps the YUV stride but is wired to the RGB565
# doorbell. Every constant involved is still a named, correct member of the
# layout header, so no single-file gate can see it.
sed 's/\.DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)/.DOORBELL_PHYS(DDR_FRAME_RGB565_DOORBELL_PHYS)/' \
  "$ROOT/fpga/Plex_MiSTer/rtl/present_core.sv" >"$WINDOW_DIR/present_mixed.sv"
if ! grep -q "DOORBELL_PHYS(DDR_FRAME_RGB565_DOORBELL_PHYS)" "$WINDOW_DIR/present_mixed.sv"; then
  echo "FAIL: instantiated-window fault 2 did not inject; the instantiation spelling changed" >&2
  exit 1
fi
if PRESENT_CORE="$WINDOW_DIR/present_mixed.sv" \
   python3 "$ROOT/tests/unit/test_rtl_invariants.py" \
     >"$WINDOW_DIR/f2.out" 2>"$WINDOW_DIR/f2.err"; then
  echo "FAIL: instantiated-window gate accepted a YUV stride wired to the RGB565 doorbell" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q "one consistent layout" "$WINDOW_DIR/f2.out" "$WINDOW_DIR/f2.err"; then
    echo "FAIL: instantiated-window mixed-family red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$WINDOW_DIR/f2.out" "$WINDOW_DIR/f2.err" >&2
    exit 1
  fi
fi

# Fault 3: the host spec points its live-probe constants at an address the
# fabric never writes. This is the exact shape of the defect that cost a worker
# hours: the probe returns valid magics, frozen, from an older core's leftovers.
sed 's/kYuv420pDoorbellAddr = 0x300FF000u/kYuv420pDoorbellAddr = 0x3007F000u/' \
  "$ROOT/host/libmisterplex/mailbox_abi_spec.hpp" >"$WINDOW_DIR/spec_stale.hpp"
if ! grep -q "kYuv420pDoorbellAddr = 0x3007F000u" "$WINDOW_DIR/spec_stale.hpp"; then
  echo "FAIL: instantiated-window fault 3 did not inject; the spec spelling changed" >&2
  exit 1
fi
if MAILBOX_ABI_SPEC="$WINDOW_DIR/spec_stale.hpp" \
   python3 "$ROOT/tests/unit/test_rtl_invariants.py" \
     >"$WINDOW_DIR/f3.out" 2>"$WINDOW_DIR/f3.err"; then
  echo "FAIL: instantiated-window gate accepted a host spec aimed at the stale window" >&2
  exit 1
else
  rc=$?
  if [[ "$rc" -ne 1 ]] \
     || ! grep -qE "probe an address the fabric never writes|stay distinct|must stay distinct" \
          "$WINDOW_DIR/f3.out" "$WINDOW_DIR/f3.err"; then
    echo "FAIL: instantiated-window stale-spec red-check returned rc=$rc, want rejection rc=1" >&2
    cat "$WINDOW_DIR/f3.out" "$WINDOW_DIR/f3.err" >&2
    exit 1
  fi
fi
echo "OK red-check: instantiated mailbox window gate rejects stride/doorbell drift, mixed layout families, and a host spec aimed at the stale window"
