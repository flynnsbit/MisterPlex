derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
# Analog raster mux: ce_pix is a clk_sys clock-enable. Do not derive_clocks
# (would invent clocks on analog enables). Do not create_generated_clock on
# ce_pix / analog HSync — 15.6 kHz is H-rate, not clk_sys. See Plex_analog_mux.sdc
# (sourced from files.qip). HDMI LCD ascal stays a separate video_mode domain.
