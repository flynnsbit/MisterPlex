// Minimal elab wrapper: plex_clk_status with clk_pix=1.5x clk for sim ratio check optional
`timescale 1ns/1ps
module plex_clk_status_meas_tb_top(
	input clk, input clk_pix, input reset, input vsync,
	output [7:0] fps_x10, output [7:0] flags, output done,
	output [31:0] pix_count, output [15:0] frm_count
);
	wire [31:0] a,b,c,d; wire [7:0] e; wire f,g; wire [15:0] h;
	plex_clk_status u(
		.clk(clk), .reset(reset), .clk_pix(clk_pix), .vsync(vsync),
		.clk_sys_hz(a), .clk_pix_hz(b), .present_ppc(e),
		.cea_pix_frame(c), .l4_pix_frame(d),
		.cea_24_needs_faster_pix(f), .l4_24_needs_faster_sys(g),
		.peak_mpix_s_x10(h), .kit_id_valid(),
		.meas_pix_count(pix_count), .meas_frame_count(frm_count),
		.meas_fps_x10(fps_x10), .meas_flags(flags), .meas_window_done(done)
	);
endmodule
