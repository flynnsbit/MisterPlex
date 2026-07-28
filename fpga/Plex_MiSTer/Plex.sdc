derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# ─────────────────────────────────────────────────────────────────────────────
# CDC timing bounds for ddr_bus_arbiter (clk_sys ↔ clk_ddr crossings)
#
# Context: ddr_bus_arbiter runs on clk_ddr (90 MHz, general[2].gpll).
# It receives m1_want from the bitstream reader (clk_sys, 20 MHz) and returns
# response data via an async_fifo (m1_rsp_fifo).  These crossings use proper
# CDC mechanisms; the functional proof is structural, but constraints must
# still keep gross routing delay visible to STA with finite bounds. Do not use
# set_clock_groups -asynchronous here.
#
# Cross-reference: w-a3 crossing inventory (30/30 SAFE), crossings #21, #22, #30.
# Source verification: ddr_bus_arbiter.sv lines 60-81 (syncs), async_fifo.sv (FIFO).
# Proof: slot13 fit shows zero 332125 combinational-loop warnings, confirming
# FIFO Gray-code structure is correct.
# ─────────────────────────────────────────────────────────────────────────────

# CONSTRAINT 1: m1_want 2-FF synchroniser, first stage (crossing #21)
# Source: ddr_bus_arbiter.sv:73-81
#   reg m1_want_s1, m1_want_s2;
#   m1_want_s1 <= m1_want;    // first capture — metastability resolved by s2
#   m1_want_s2 <= m1_want_s1;
# Safety: metastability at s1 is resolved by s2 before any logic samples it.
# Bound rather than false-path so STA still reports gross routing mistakes.
set_max_delay -to [get_keepers {*ddr_arb|m1_want_s1}] 50.0

# CONSTRAINT 2: reset synchroniser, first stage (crossing #22)
# Source: ddr_bus_arbiter.sv:60-68
#   reg reset_s1, reset_s2;
#   reset_s1 <= 1'b0; (or 1'b1 on async assert)
#   reset_s2 <= reset_s1;
# Safety: same 2-FF pattern as m1_want; metastability resolved before use.
set_max_delay -to [get_keepers {*ddr_arb|reset_s1}] 50.0

# CONSTRAINT 3: async_fifo write-pointer Gray-code sync into read domain
# Source: async_fifo.sv:71-72
#   wr_gray_r1 <= wr_gray;    // first capture in rd_clk domain
#   wr_gray_r2 <= wr_gray_r1;
# Safety: Gray-code guarantees at most 1 bit changes per cycle; metastability
# on that single bit is resolved by wr_gray_r2 before rd_empty logic uses it.
set_max_delay -to [get_keepers {*m1_rsp_fifo|wr_gray_r1[*]}] 50.0

# CONSTRAINT 4: async_fifo read-pointer Gray-code sync into write domain
# Source: async_fifo.sv:54-55
#   rd_gray_w1 <= rd_gray;    // first capture in wr_clk domain
#   rd_gray_w2 <= rd_gray_w1;
# Safety: same pattern; full/almost_full uses rd_gray_w2 only.
set_max_delay -to [get_keepers {*m1_rsp_fifo|rd_gray_w1[*]}] 50.0

# CONSTRAINT 5: async_fifo RAM data path — set_max_delay, NOT set_false_path
# Source: async_fifo.sv:23 (reg [AW:0] wr_bin), line 46 (mem[wr_bin[AW-1:0]])
#
# WHY NOT false_path: Gray-coded pointers guarantee the reader does not sample
# before the writer has written — but they say nothing about RAM output routing
# delay.  If the data path is unconstrained, the fitter may route it arbitrarily
# long.  If RAM output delay exceeds the pointer sync latency, the reader samples
# a valid address but gets data that has not physically arrived.
#
# Bound: destination clock period (clk_sys = 50 ns).  The pointer sync takes
# 2 rd_clk cycles (~100 ns) so 50 ns provides 2× margin on the actual safety
# window while preventing absurd routing.
#
# NOTE: Quartus 17.0.2 does not support -datapath_only.  Plain set_max_delay
# includes clock uncertainty (~200ps for same-PLL clocks), which is negligible
# against a 50 ns bound on a path measuring ~7.5 ns.  Functionally equivalent.
#
# Wildcard expansion (verified from slot13 STA):
#   *ddr_arb*m1_rsp_fifo|mem~14   (register cell, 64-bit word 0)
#   *ddr_arb*m1_rsp_fifo|mem~142  (register cell, 64-bit word 1)
# These are the only register-type keepers matching this pattern.
# Combinational nodes (mem~588, mem~844) are read-mux logic, not keepers.
set_max_delay -from [get_keepers {*ddr_arb*m1_rsp_fifo|mem*}] 50.0

# No ddr_frame_store diagnostic false-path is applied here. The current RTL
# transfers underruns into clk_ddr via frame_miss_toggle/frame_underrun_ddr
# before frame_status_ddr/frame_mbox_last, so a direct underrun_count cut would
# be obsolete at best and misleading at worst.
