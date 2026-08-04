// TB top: Gray + period refresh measure (product 30 MHz → 24.242).
`timescale 1ns/1ps
module plex_clk_refresh_meas_tb_top (
	input  wire clk,
	input  wire reset,
	input  wire clk_pix,
	input  wire vsync,
	input  wire ce_pix,
	input  wire de,
	output wire [7:0]  meas_fps_x10,
	output wire [7:0]  meas_flags,
	output wire        meas_done,
	output wire [15:0] meas_frames,
	output wire [31:0] meas_pix,
	output wire [31:0] meas_ce,
	output wire [31:0] meas_de
);
`ifndef TB_MEAS_WIN
	`define TB_MEAS_WIN 20000
`endif
	plex_clk_status #(.MEAS_WINDOW_CYCLES(`TB_MEAS_WIN)) u (
		.clk(clk), .reset(reset), .clk_pix(clk_pix), .vsync(vsync),
		.ce_pix(ce_pix), .de(de),
		.clk_sys_hz(), .clk_pix_hz(), .present_ppc(),
		.cea_pix_frame(), .l4_pix_frame(),
		.cea_24_needs_faster_pix(), .l4_24_needs_faster_sys(),
		.peak_mpix_s_x10(), .kit_id_valid(),
		.meas_pix_count(meas_pix), .meas_ce_count(meas_ce),
		.meas_de_count(meas_de), .meas_frame_count(meas_frames),
		.meas_fps_x10(meas_fps_x10), .meas_flags(meas_flags),
		.meas_window_done(meas_done)
	);
endmodule
