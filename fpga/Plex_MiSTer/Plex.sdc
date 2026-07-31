derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# async_fifo data plane (all instances, dominant: ddr_bus_arbiter.m1_rsp_fifo):
# mem[] is written on wr_clk and sampled into rd_data_r on rd_clk. Gray pointer
# synchronisers are the real CDC (docs/cdc-crossing-inventory.md crossings
# #16/#22/#30). general[0] (clk_sys 20 MHz) and general[2] (clk_ddr 90 MHz)
# share one set_clock_groups -exclusive group in sys_top.sdc, so STA applies a
# related-edge relationship of 5.556 ns across this intentional async path.
# That is placement-fragile, not a want_y logic failure:
#   ac90b155: m1_rsp_fifo mem→rd_data_r setup +0.502 (data delay 4.111)
#   ff2e3ca3: same class setup -0.233 (data delay 4.892) and hold -0.517
#             (hold relationship 0.001 ns — related-edge artifact)
# Quartus 17.0 has no set_max_delay -datapath_only. Cut ONLY the FIFO data
# keepers (mem→rd_data_r). Do NOT cut the whole general[0]↔general[2] pair
# (other same-group paths e.g. fstore DDRAM_ADDR must stay timed).
set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]
