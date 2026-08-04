// TB top: product geometry defaults (1650×750 / DE 1280×720).
// rd-duck: VSync-only is insufficient; per-frame CE/lines/DE must match.
`timescale 1ns/1ps
module plex_clk_refresh_meas_tb_top (
	input  wire clk,
	input  wire reset,
	input  wire clk_pix,
	input  wire vsync,
	input  wire hsync,
	input  wire ce_pix,
	input  wire de,
	input  wire [15:0] underrun_count,
	output wire [7:0]  meas_fps_x10,
	output wire [7:0]  meas_flags,
	output wire        meas_done,
	output wire [15:0] meas_frames,
	output wire [31:0] meas_pix,
	output wire [31:0] meas_ce,
	output wire [31:0] meas_de,
	output wire [31:0] meas_ce_frame,
	output wire [31:0] meas_de_frame,
	output wire [15:0] meas_lines,
	output wire [15:0] meas_active,
	output wire [15:0] meas_ce_line
);
`ifndef TB_MEAS_WIN
	`define TB_MEAS_WIN 20000
`endif
	// Product COMPACT geometry (matches present_video_timing_720p / present_core)
	plex_clk_status #(
		.MEAS_WINDOW_CYCLES(`TB_MEAS_WIN),
		.H_TOTAL(1650),
		.V_TOTAL(750),
		.H_ACTIVE(1280),
		.V_ACTIVE(720)
	) u (
		.clk(clk), .reset(reset), .clk_pix(clk_pix),
		.vsync(vsync), .hsync(hsync),
		.ce_pix(ce_pix), .de(de),
		.underrun_count(underrun_count),
		.clk_sys_hz(), .clk_pix_hz(), .present_ppc(),
		.cea_pix_frame(), .l4_pix_frame(),
		.cea_24_needs_faster_pix(), .l4_24_needs_faster_sys(),
		.peak_mpix_s_x10(), .kit_id_valid(),
		.meas_pix_count(meas_pix), .meas_ce_count(meas_ce),
		.meas_de_count(meas_de), .meas_frame_count(meas_frames),
		.meas_ce_frame(meas_ce_frame), .meas_de_frame(meas_de_frame),
		.meas_lines_frame(meas_lines), .meas_active_lines(meas_active),
		.meas_ce_line(meas_ce_line),
		.meas_fps_x10(meas_fps_x10), .meas_flags(meas_flags),
		.meas_window_done(meas_done)
	);
endmodule
