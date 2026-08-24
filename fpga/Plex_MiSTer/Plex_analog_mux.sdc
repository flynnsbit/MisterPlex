# Plex_analog_mux.sdc — analog raster mux STA (product; sourced from files.qip).
#
# ce_pix is a clk_sys clock-enable (registered data), not a clock.
# analog_raster_mux / colorbars FFs are all posedge clk (clk_sys). Nothing
# in the analog mux is posedge ce_pix. 15.6 kHz is analog H-rate, not STA.
#
# Product clk_sys = PLL out0 20.000 MHz (24.000 only if PLEX_CLK_SYS_24).
# Analog H-rate = Fclk / (H_TOTAL * ce_div), ce_div=2 when ~scandouble:
#   sel0/2 240p/480i: ce_pix toggles, H_TOTAL=638 → 20e6/1276 = 15674 Hz
#   sel1 480p:        ce_pix=1,      H_TOTAL=638 → 20e6/638  = 31348 Hz
# HDMI ascal video_mode is independent (Main scaler). This file does not
# constrain HDMI Fpix. HDMI LCD scoring stays >=31 kHz (display_raster.hpp).
#
# FORBIDDEN on a future sole fit (would invent a 15.6 kHz / 10 MHz clock):
#   create_generated_clock -divide_by 2    [... ce_pix ...]
#   create_generated_clock -divide_by 1276 [... HSync ...]
#   create_clock -period 63800 ...           ;# 15.6 kHz as a fabric clock
#   derive_clocks                            ;# TimeQuest infers clocks on enables
# Do not retune clk_sys to "make 240p." STA Fmax remains general[0] 20.000 MHz.
# Do not set_multicycle_path on ce_pix-gated analog paths: HBlank/HSync sample
# every clk_sys tick (colorbars), so a silent MC2 would hide real 20 MHz paths.
#
# CDC / analog_sel:
#   OSD Display O[15:14] → analog_sel (Plex.sv). w-fpga reset-latches analog_sel;
#   analog_raster_mux.sel_lat is reset-only (not fstart, not live F12).
#   Treat analog_sel as a run-constant. Do not time F12 hops as per-line data.
#   HPS analog doorbell PLXH 0x3007F138 (NOT leftover L4 0x3047F130): 2FF into
#   clk_sys (db_sel_s1/db_v_s1), snapshot at reset into sel_lat. Do not
#   create_generated_clock from the doorbell. Content O[5:4] stays live and
#   is NOT false-pathed here.
#
# sel_lat is a 2-bit reset-time constant (scandouble_act). False-path its D
# pin so STA does not treat OSD status[15:14] / PLXH as a every-cycle analog
# hop. Do not false_path FROM sel_lat (scandouble → ce_pix mux is a real
# clk_sys path and must stay timed).
set_false_path -to {*sel_lat*}
# Analog doorbell CDC: clk_ddr analog_db_* → clk_sys 2FF first stage.
set_false_path -to {*db_sel_s1*}
set_false_path -to {*db_v_s1*}
