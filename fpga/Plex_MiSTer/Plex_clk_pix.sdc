# Plex_clk_pix.sdc — constraints for PRESENT_CLK_PIX_PLL (default OFF).
#
# Product QSF does NOT source this file. Enable only with the fit recipe:
#   set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
#   set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
#   set_global_assignment -name SDC_FILE Plex_clk_pix_cdc.sdc  ;# w-mem CDC (if present)
#
# PRODUCT rate: 720p24 COMPACT → clk_pix 28.800000 MHz EXACT on SHARED pll_0002
#   outclk_3 / general[3]. fps_eff = 28.8e6/(1600*750) = 24.000 Hz.
# PRESENT_CLK_PIX_74_25 → 74.250000 MHz (VIC-4 60 Hz) — out of scope default.
#
# Base Plex.sdc already runs derive_pll_clocks. This file names domains and
# exclusive async groups so STA does not invent related-edge paths across
# async FIFO crossings (present_npx_path). w-mem owns max/min_delay CDC file.
#
# Unconstrained clk_pix is a false green — FAIL if clock missing or unanalyzed.

set plex_clk_sys {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set plex_clk_ddr {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
# Shared PLL outclk_3 = clk_pix (product 28.800000 MHz)
set plex_clk_pix {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}

# --- Empty-clock / zero-path guard (false-green prevention) ---
set _pix_clks [get_clocks -nowarn $plex_clk_pix]
if {[llength $_pix_clks] == 0} {
	post_message -type error "Plex_clk_pix.sdc: clk_pix clock not found at $plex_clk_pix — PRESENT_CLK_PIX_PLL fit must derive general[3]. Unconstrained clk_pix is a false green."
} else {
	# Require at least one timing path involving clk_pix after report collection.
	# (Checked again by scripts/check_clk_pix_sta_guard.py on STA_RPT.)
	post_message -type info "Plex_clk_pix.sdc: found clk_pix [get_clock_info -name [lindex $_pix_clks 0]]"
}

# Exclusive: clk_pix crossed only via async_fifo gray + 2FF (present_npx_path).
# w-mem Plex_clk_pix_cdc.sdc adds max/min_delay on RGB/CE keepers — do not undo.
set_clock_groups -asynchronous \
	-group [get_clocks $plex_clk_sys] \
	-group [get_clocks $plex_clk_pix]

set_clock_groups -asynchronous \
	-group [get_clocks $plex_clk_ddr] \
	-group [get_clocks $plex_clk_pix]

# Parent STA after clk_pix-enabled fit:
#   make post-fit-timing STA_RPT=OUT/Plex.sta.rpt
#   python3 scripts/check_clk_pix_sta_guard.py STA_RPT=OUT/Plex.sta.rpt
# HARD expects:
#   - Fmax of general[3] clk_pix >= 28.8 MHz (or >= 74.25 if 74_25)
#   - Setup slack clk_pix domain: no negative TNS
#   - clk_ddr worst slack still >= 0
#   - clk_pix present in STA with analyzed paths > 0
#   - No decode_stub as Fmax owner (PRODUCT_NO_STUB)
#
# Do NOT add false_path on residual_csum / decode sameclk paths.
