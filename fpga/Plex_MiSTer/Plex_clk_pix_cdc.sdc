# Plex_clk_pix_cdc.sdc — w-mem CDC constraints for dedicated/async clk_pix.
#
# OWNERSHIP: w-clock owns Plex_clk_pix.sdc (clock names + set_clock_groups).
# This file is SEPARATE — do not merge blindly. Enable with the same recipe:
#   set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
#   set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
#   set_global_assignment -name SDC_FILE Plex_clk_pix_cdc.sdc
#
# Policy:
#   - Genuine async domains: set_clock_groups lives in Plex_clk_pix.sdc
#   - Handshake/FIFO data: set_max_delay / set_min_delay on keepers
#     (NOT a blanket set_false_path on the data bus — parent rejects false green)
#   - 2FF sync chains: small max_delay dst-period budget; preserve in RTL
#
# Clock name strings must match Plex_clk_pix.sdc / w-clock dedicated PLL path.
# If w-clock renames the generator (dedicated pll_pix vs general[3]), update BOTH.

set plex_clk_sys {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
set plex_clk_ddr {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}
set plex_clk_pix {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
# w-clock dedicated PLL (when landed) — alternate name; harmless if missing:
set plex_clk_pix_ded {emu|pll_pix|*}

# Periods (ns)
set Tsys 50.000
set Tpix 33.670

# --- async_fifo data plane present_npx (sys→pix) ---
# Gray pointers are the control CDC; mem→rd_data_r is payload held stable by
# protocol. Bound skew to one destination period so STA still checks routing.
# Do NOT set_false_path here (Plex.sdc false_path is sys↔ddr related-edge only).
if {[llength [get_clocks -nowarn $plex_clk_sys]] && [llength [get_clocks -nowarn $plex_clk_pix]]} {
	set_max_delay -from [get_keepers {*|u_mp_npx_path|u_pix_fifo|mem*}] \
		-to   [get_keepers {*|u_mp_npx_path|u_pix_fifo|rd_data_r*}] $Tpix
	set_min_delay -from [get_keepers {*|u_mp_npx_path|u_pix_fifo|mem*}] \
		-to   [get_keepers {*|u_mp_npx_path|u_pix_fifo|rd_data_r*}] 0.000

	# prefill_go 2FF + frame_start toggle 2FF: single-bit control
	set_max_delay -from [get_clocks $plex_clk_sys] -to [get_keepers {*|u_prefill_go_sync|sync_r*}] $Tpix
	set_max_delay -from [get_clocks $plex_clk_pix] -to [get_keepers {*|u_mp_fstart_cdc|*sync_r*}] $Tsys
}

# Request for w-clock (do not edit Plex_clk_pix.sdc from this lane):
#   If dedicated pll_pix lands, replace $plex_clk_pix path string and keep
#   set_clock_groups -asynchronous clk_pix ⊥ {clk_sys, clk_ddr}.
#   Do not add set_false_path on RGB/CE_PIXEL buses.
