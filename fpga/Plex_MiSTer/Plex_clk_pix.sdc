# Plex_clk_pix.sdc — constraints for PRESENT_CLK_PIX_PLL (default OFF).
#
# Product QSF does NOT source this file. Enable only with the compose fit recipe
# (product FRAME already 1280x720 on main; macros default-OFF):
#   set_global_assignment -name VERILOG_MACRO "PRESENT_MULTI_PIXEL=1"
#   set_global_assignment -name VERILOG_MACRO "PRESENT_PX_PER_CLK=1"
#   set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
#   set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
# See docs/PRESENT_CLK_PIX_PLL_ENABLE.md. Never MULTI@CEA totals without this
# PLL — that is the ~16.16 Hz trap (20e6/1_237_500).
#
# Base Plex.sdc already runs derive_pll_clocks. This file names the new domain,
# documents CDC policy, and adds exclusive groups so STA does not invent
# related-edge paths across async FIFO crossings.
#
# Frequencies (from pll_0002.v SoT):
#   clk_sys  = general[0] = 20.000 MHz
#   clk_ddr  = general[2] = 90.000 MHz
#   clk_pix  = general[3] = 29.700 MHz  (or 74.250 with PRESENT_CLK_PIX_74_25)
# PIX_PER_FRAME pack = 1650*750 = 1_237_500; f_pix@24 = 29_700_000 exact.
#
# RTL contract (Plex.sv): with MULTI+PLL, CLK_VIDEO = clk_pix_pll so CE_PIXEL /
# VGA_* stay same-domain as present_npx_path unpack.
#
# Do NOT add false_path on residual_csum / decode sameclk paths.
# Do NOT weaken setup to hide real violations.

# Named PLL output pins (Cyclone V altera_pll counter path — same family as STA dumps).
set plex_clk_sys {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set plex_clk_ddr {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
set plex_clk_pix {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}

# Exclusive: clk_pix is crossed only via async_fifo gray pointers + 2FF levels
# (present_npx_path). Treat as asynchronous to clk_sys / clk_ddr.
# If a future design intentionally uses related-edge multicycle between these,
# remove this group and add proven multicycle — never a silent false_path.
set_clock_groups -asynchronous \
	-group [get_clocks $plex_clk_sys] \
	-group [get_clocks $plex_clk_pix]

set_clock_groups -asynchronous \
	-group [get_clocks $plex_clk_ddr] \
	-group [get_clocks $plex_clk_pix]

# clk_sys <-> clk_ddr remain related (existing product CDC inventory). Do not
# put them in exclusive groups here.

# Period sanity (derive_pll_clocks should already create these; explicit
# create_generated_clock is NOT used — PLL is the generator).
# Parent STA one-pass after fit:
#   scripts/sta_onepass_interrogation.sh OUT/Plex.sta.rpt OUT/clk_sys_sameclk_setup.txt
# Interrogate ALSO:
#   - Fmax of general[3] (clk_pix) >= 29.7 (or 74.25)
#   - No setup fail inside present_npx_path on clk_pix
#   - No decode_stub as Fmax owner (parent miss #18)
