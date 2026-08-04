# PRESENT_CLK_PIX_PLL constraints (DEFAULT OFF — source only with the macro).
# derive_pll_clocks (Plex.sdc / sys_top.sdc) creates:
#   general[0] = clk_sys  20.000 MHz
#   general[2] = clk_ddr  90.000 MHz
#   general[3] = clk_pix  29.700 MHz (or 74.25)
#
# CDC discipline (source-proven, present_npx_path.sv):
#   sys → pix: async_fifo gray pointers + 2FF on prefill_go
#   No bare multi-bit control without gray/FIFO.
# Therefore related-clock STA across sys/pix would be false; cut with
# asynchronous clock groups. Do NOT false_path residual_csum or other
# same-clock paths (gate self-weakening).
#
# Negative slack on general[3] after fit is a HARD FAIL (post-fit-timing).

set clk_sys_pll {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set clk_ddr_pll {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
set clk_pix_pll {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}

# Only apply if derive_pll_clocks created clk_pix (macro enabled in fit).
if {[llength [get_clocks -quiet $clk_pix_pll]] > 0} {
	set_clock_groups -asynchronous \
		-group [get_clocks $clk_sys_pll] \
		-group [get_clocks $clk_pix_pll]
	set_clock_groups -asynchronous \
		-group [get_clocks $clk_ddr_pll] \
		-group [get_clocks $clk_pix_pll]
}
