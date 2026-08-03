# =============================================================================
# Plex_native720p24.sdc — FIT GRANT ONLY (native 720p24 preferred mode)
# =============================================================================
# Mode: clk_sys = 24.000 MHz, clk_ddr = 90.000 MHz, DE 1280x720, H=1312, V=762
#        -> core beam fps = 24e6/(1312*762) = 24.006146 Hz (~1:1 with 24/1 content)
#
# USAGE (parent fit):
#   1. Apply PLL edit in PLL_EDIT.md (pll_0002.v out0 20->24) BEFORE compile
#   2. Include this file INSTEAD OF or AFTER fpga/Plex_MiSTer/Plex.sdc
#      Project settings: SDC_FILE = this path (or cat into Plex.sdc under grant)
#   3. Keep sys_top.sdc (FPGA_CLK* + derive_pll_clocks + HPS clocks)
#   4. Do NOT use this SDC on the shipping 20 MHz product without reverting PLL
#
# SoT PLL strings must match pll_0002.v after the grant edit.
# Corner that counts: Slow 1100mV 100C Final (see STA_PASS_CRITERIA.md)
# =============================================================================

derive_pll_clocks
derive_clock_uncertainty

# -----------------------------------------------------------------------------
# Expected PLL-derived fabric clocks (documentation + optional name anchors).
# altera_pll under derive_pll_clocks creates:
#   *|pll_0002|*|altera_pll_i|*general[0]*|divclk  = clk_sys  24.000 MHz
#   *|pll_0002|*|altera_pll_i|*general[1]*|divclk  = SDRAM clk (unchanged family)
#   *|pll_0002|*|altera_pll_i|*general[2]*|divclk  = clk_ddr  90.000 MHz
#
# Periods:
#   clk_sys 24.000 MHz -> 41.666666... ns
#   clk_ddr 90.000 MHz -> 11.111111... ns
#
# Related-clock family (same VCO ~360 MHz class, fractional=false):
#   24:90 = 4:15  (NOT integer 3:1 — see RISKS.md CDC)
#   Prior 20:90 min rising relationship was 5.556 ns (MEASURED on old fits).
#   24:90 relationship is RECOMPUTED by TimeQuest from the new PLL — do not
#   paste 5.556 or invent a false_path for the whole pair.
# -----------------------------------------------------------------------------

# Optional explicit period checks if auto-names differ across Quartus builds.
# Uncomment ONLY if derive_pll_clocks leaves clk_sys unconstrained (should not).
# create_generated_clock -name clk_sys_24 \
#   -source [get_pins -compatibility_mode *|pll_0002|*|refclk] \
#   -divide_by 15 -multiply_by 36 \
#   [get_pins -compatibility_mode *|pll_0002|*general[0]*|divclk]
# (Prefer derive_pll_clocks output names from the .sta.rpt "Clocks" panel.)

# -----------------------------------------------------------------------------
# async_fifo data plane — intentional CDC (unchanged policy from product SDC).
# Cut ONLY mem[] -> rd_data_r keepers. Do NOT cut whole clk_sys <-> clk_ddr.
# Do NOT add multicycle/false_path to hide residual_csum or beam paths.
# -----------------------------------------------------------------------------
set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]

# -----------------------------------------------------------------------------
# Native 720p24 mode markers (comments for humans + fitgate greps)
# FIT_MODE=native_720p24
# CLK_SYS_MHZ=24.000
# CLK_DDR_MHZ=90.000
# BEAM_H_TOTAL=1312
# BEAM_V_TOTAL=762
# BEAM_DE=1280x720
# BEAM_FPS_ARITH=24.006146
# CORNER_REQUIRED=Slow 1100mV 100C Final
# FMAX_CLK_SYS_MIN_MHZ=24.000
# PATH_OWNER_FORBIDDEN=decode_stub
# -----------------------------------------------------------------------------
