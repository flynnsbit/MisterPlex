# Plex_clk_pix.sdc — constraints for PRESENT_CLK_PIX_PLL (default OFF).
#
# Product QSF does NOT source this file. Enable only with the fit recipe:
#   set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
#   set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
# Product rate is 720p24 → clk_pix 30.000 MHz (NOT 74.25 unless PRESENT_CLK_PIX_74_25).
#
# Base Plex.sdc already runs derive_pll_clocks. This file names the new domain,
# documents CDC policy, and adds exclusive groups so STA does not invent
# related-edge paths across async FIFO crossings.
#
# Frequencies (pll_0002.v SoT; refclk 50.0 MHz):
#   clk_sys  = general[0] = 20.000 MHz  (CLK_SYS_24 → 24.000)
#   clk_ddr  = general[2] = 90.000 MHz
#   clk_pix  = general[3] = 30.000 MHz  (or 74.250 with PRESENT_CLK_PIX_74_25)
#
# Exact integer M/N/C from 50 MHz exist (0 ppm if chosen) — see
# rtl/misterplex_clk_pix_recipe.svh. Fitted counters UNKNOWN until fit "Actual".
#
# pll_hdmi is a SEPARATE fractional PLL (typically 148.5 MHz) + pll_hdmi_adj.
# This SDC does not retarget pll_hdmi. CLK_VIDEO is driven from clk_pix in Plex.sv
# when PRESENT_CLK_PIX_PLL is on; ascal/video_mixer consume CLK_VIDEO.
#
# Post-strip STA (parent nostub-poststrip1; clk_pix was OFF in that fit):
#   emu pll general[2] (clk_ddr) slack +0.311 ns  ← worst path, thin
#   emu pll general[0] (clk_sys) slack +1.290 ns
#   pll_hdmi counter[0] slack +0.571 ns
#   TNS 0.000 all
# That fit does NOT measure clk_pix Fmax. Next fit with PRESENT_CLK_PIX_PLL must
# re-interrogate general[3]. Thin +0.311 on clk_ddr is a risk if fabric DMA adds
# TIMING NAME LOCK: default 30.000 MHz is COMPACT H1650×V750×24 fabric raster.
# It is NOT CEA-861 720p24 (VIC60 = 59.4 MHz, Htotal 3300). True CEA24 uses
# PRESENT_CLK_PIX_CEA24. CEA 720p60 VIC4 = 74.25 MHz (PRESENT_CLK_PIX_74_25).
# DDR traffic — not proof that 30.0 clk_pix is impossible.
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

# Period sanity: derive_pll_clocks creates clocks from PLL generics.
# Explicit create_clock on divclk is not used — PLL is the generator.
#
# Parent STA one-pass after a clk_pix-enabled fit:
#   scripts/sta_onepass_interrogation.sh OUT/Plex.sta.rpt OUT/clk_sys_sameclk_setup.txt
#   make post-fit-timing STA_RPT=OUT/Plex.sta.rpt
#   make post-fit-timing-margin STA_RPT=OUT/Plex.sta.rpt
# HARD expects (clk_pix fit):
#   - Fmax of general[3] (clk_pix) >= 30.0 MHz (or >= 74.25 if 74_25 macro)
#   - Setup slack on clk_pix domain: no negative TNS
#   - No setup fail inside present_npx_path on clk_pix
#   - clk_ddr worst slack still >= 0 (watch +0.311 budget if DMA lands)
#   - No decode_stub as Fmax owner (PRODUCT_NO_STUB)
#   - NEW_RBF not in banned hash list
