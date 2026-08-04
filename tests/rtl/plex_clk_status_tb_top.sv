`timescale 1ns/1ps
// Default product macros: no CLK_SYS_24, no PRESENT_CLK_PIX_PLL, PPC=1
module plex_clk_status_tb_top (
	input  wire        clk,
	input  wire        reset,
	output wire [31:0] clk_sys_hz,
	output wire [31:0] clk_pix_hz,
	output wire [7:0]  present_ppc,
	output wire [31:0] cea_pix_frame,
	output wire [31:0] l4_pix_frame,
	output wire        cea_24_needs_faster_pix,
	output wire        l4_24_needs_faster_sys,
	output wire [15:0] peak_mpix_s_x10,
	output wire        kit_id_valid
);
	plex_clk_status dut (
		.clk(clk),
		.reset(reset),
		.clk_sys_hz(clk_sys_hz),
		.clk_pix_hz(clk_pix_hz),
		.present_ppc(present_ppc),
		.cea_pix_frame(cea_pix_frame),
		.l4_pix_frame(l4_pix_frame),
		.cea_24_needs_faster_pix(cea_24_needs_faster_pix),
		.l4_24_needs_faster_sys(l4_24_needs_faster_sys),
		.peak_mpix_s_x10(peak_mpix_s_x10),
		.kit_id_valid(kit_id_valid)
	);
endmodule
