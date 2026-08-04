# Plex_clk_pix.sdc — constraints for PRESENT_CLK_PIX_PLL (default OFF).
#
# Product QSF does NOT source this file. Enable only with the fit recipe:
#   set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
#   set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
#
# PRODUCT rate: 720p24 COMPACT → clk_pix 29.700000 MHz EXACT
#   (dedicated pll_pix VCO=1485 C=50; NOT shared pll_0002 outclk_3)
#   fps_eff = 29.7e6/(1650*750) = 24.000 Hz exact
# PRESENT_CLK_PIX_74_25 → 74.250000 MHz (VIC-4 60 Hz) on same dedicated PLL.
#
# Base Plex.sdc already runs derive_pll_clocks. This file names domains and
# exclusive async groups so STA does not invent related-edge paths across
# async FIFO crossings (present_npx_path).
#
# Fabric PLL (pll_0002) remains 3 clocks only:
#   clk_sys  = general[0] = 20.000 MHz
#   clk_ddr  = general[2] = 90.000 MHz
# clk_pix is emu|u_pll_pix|pll_pix_inst|altera_pll_i|general[0]...
#
# Unconstrained clk_pix is a false green — this SDC must be sourced when macro on.
#
# Do NOT add false_path on residual_csum / decode sameclk paths.

set plex_clk_sys {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set plex_clk_ddr {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
# Dedicated pix PLL (instance u_pll_pix in Plex.sv → pll_pix → pll_pix_0002)
set plex_clk_pix {emu|u_pll_pix|pll_pix_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}

# Exclusive: clk_pix crossed only via async_fifo gray + 2FF (present_npx_path).
set_clock_groups -asynchronous \
	-group [get_clocks $plex_clk_sys] \
	-group [get_clocks $plex_clk_pix]

set_clock_groups -asynchronous \
	-group [get_clocks $plex_clk_ddr] \
	-group [get_clocks $plex_clk_pix]

# Parent STA after clk_pix-enabled fit:
#   make post-fit-timing STA_RPT=OUT/Plex.sta.rpt
# HARD expects:
#   - Fmax of dedicated general[0] clk_pix >= 29.7 MHz (or >= 74.25 if 74_25)
#   - Setup slack clk_pix domain: no negative TNS
#   - clk_ddr worst slack still >= 0
#   - No decode_stub as Fmax owner (PRODUCT_NO_STUB)
