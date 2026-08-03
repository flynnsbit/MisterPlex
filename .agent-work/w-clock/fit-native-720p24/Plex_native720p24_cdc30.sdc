# =============================================================================
# Plex_native720p24_cdc30.sdc — PRIMARY fit grant (CDC-first native ~24 Hz beam)
# =============================================================================
# clk_sys=30.000 MHz, clk_ddr=90.000 MHz (3:1), DE 1280x720, H=1312, V=953
# fps = 30e6/(1312*953) ≈ 23.9936 Hz
# Corner that counts: Slow 1100mV 100C Final
# Do NOT use 24 MHz SDC as primary — see CDC_RATIO_24_90_AUDIT.md BLOCKER
# =============================================================================

derive_pll_clocks
derive_clock_uncertainty

# Expected after PLL edit:
#   general[0] clk_sys = 30.000 MHz  (period 33.333 ns)
#   general[2] clk_ddr = 90.000 MHz  (period 11.111 ns)
#   min related setup Δ (aligned) = 11.111 ns (3:1)
# Hold: same-edge family — must show hold slack >= 0 in STA (not optional).

set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]

# FIT_MODE=native_720p24_cdc30
# CLK_SYS_MHZ=30.000
# CLK_DDR_MHZ=90.000
# BEAM_H_TOTAL=1312
# BEAM_V_TOTAL=953
# BEAM_DE=1280x720
# BEAM_FPS_ARITH=23.993551
# CORNER_REQUIRED=Slow 1100mV 100C Final
# FMAX_CLK_SYS_MIN_MHZ=30.000
# PATH_OWNER_FORBIDDEN=decode_stub
# CDC_RATIO=1:3
