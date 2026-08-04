`default_nettype none
module present_nn_linebuf_scaler_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [10:0] content_w,
	input  wire [10:0] de_w,
	input  wire        wr_valid,
	input  wire [10:0] wr_x,
	input  wire [23:0] wr_pix,
	input  wire        wr_line_done,
	input  wire        rd_en,
	input  wire [10:0] rd_x,
	input  wire        rd_use_prev,
	output wire [23:0] rd_pix,
	output wire        rd_valid,
	output wire [15:0] m10k_ideal_c,
	output wire [31:0] rd_bw_content_lines,
	output wire [31:0] rd_bw_glass_hits,
	output wire        cfg_ok
);
	present_nn_linebuf_scaler #(
		.CONTENT_W_MAX(1280),
		.DE_W_MAX(1280),
		.LINE_HOLD(2),
		.PIX_W(24)
	) u_dut (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.content_w(content_w),
		.de_w(de_w),
		.wr_valid(wr_valid),
		.wr_x(wr_x),
		.wr_pix(wr_pix),
		.wr_line_done(wr_line_done),
		.rd_en(rd_en),
		.rd_x(rd_x),
		.rd_use_prev(rd_use_prev),
		.rd_pix(rd_pix),
		.rd_valid(rd_valid),
		.m10k_ideal_c(m10k_ideal_c),
		.rd_bw_content_lines(rd_bw_content_lines),
		.rd_bw_glass_hits(rd_bw_glass_hits),
		.cfg_ok(cfg_ok)
	);
endmodule
`default_nettype wire
