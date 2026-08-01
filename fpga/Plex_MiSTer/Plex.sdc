derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# async_fifo data plane (all instances, dominant: ddr_bus_arbiter.m1_rsp_fifo):
# CUT: mem[] (wr_clk write) → rd_data_r (rd_clk sample). ONLY these keepers.
# NOT cut: gray 2FF chains, bin counters, full/empty, non-FIFO sys↔ddr paths.
#
# Control CDC is Gray pointers (async_fifo.sv):
#   wr publish gray:65-67  rd 2FF wr_gray_r1/r2:81-82  rd sample mem:84
#   rd publish gray:86     wr 2FF rd_gray_w1/w2:62-63
#   empty: rd_has_entry=(rd_gray!=wr_gray_r2):43  full uses rd_gray_w2:38-39
# Inventory SAFE: docs/cdc-crossing-inventory.md #16 #22 #23; module section.
# Full write-up: .agent-work/w-fit-1/SDC_FALSE_PATH_JUSTIFICATION.md
#
# Why false_path: general[0] (20 MHz) and general[2] (90 MHz) share one
# set_clock_groups -exclusive group → STA related-edge 5.556 ns on this
# intentional async datapath (placement-fragile, not want_y logic):
#   ac90b155: mem→rd_data_r setup +0.502 (data delay 4.111)
#   ff2e3ca3: setup -0.233 (4.892) hold -0.517 (hold rel 0.001 ns artifact)
# Quartus 17.0: no set_max_delay -datapath_only. Do NOT split clock groups
# (would untime fstore DDRAM_ADDR etc). Stuck bank-swap is sys-clk control
# (ddr_frame_store SWAP_REQ_HOLDS_PENDING), not this FIFO data cut.
set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]
