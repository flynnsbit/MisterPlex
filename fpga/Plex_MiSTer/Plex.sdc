derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# The video/control clock (PLL outclk_0, 20 MHz) and SDRAM controller clock
# (PLL outclk_1, selected by SDRAM_CLK_* macros) communicate only through
# explicit CDC structures/staging in frame_store/present_core. Treat them as
# asynchronous so TimeQuest does not require impossible fractional PLL phase
# relationships between the product frame path and the SDRAM bus pipeline.
set_clock_groups -asynchronous \
	-group [get_clocks {emu|pll|pll_inst|altera_pll_i|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk}] \
	-group [get_clocks {emu|pll|pll_inst|altera_pll_i|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk}]
