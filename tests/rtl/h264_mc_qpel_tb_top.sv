// Testbench-only wrapper: real serialized MC interpolator RTL (luma + chroma).
// No behavioral golden inside — the C++ TB owns the H.264 reference model.
`default_nettype none

module h264_mc_qpel_tb_top (
	input  wire        clk,
	input  wire        reset,

	// ---- Luma 16x16 qpel ----
	input  wire        luma_win_wr,
	input  wire [8:0]  luma_win_addr,
	input  wire [7:0]  luma_win_data,
	input  wire        luma_start,
	input  wire [1:0]  luma_frac_x,
	input  wire [1:0]  luma_frac_y,
	output wire        luma_busy,
	output wire        luma_done,
	input  wire [7:0]  luma_pred_rd_idx,
	output wire [7:0]  luma_pred_rd_data,

	// ---- Chroma 8x8 1/8-pel (U/V) ----
	input  wire        chroma_win_u_wr,
	input  wire        chroma_win_v_wr,
	input  wire [6:0]  chroma_win_addr,
	input  wire [7:0]  chroma_win_data,
	input  wire        chroma_start,
	input  wire [2:0]  chroma_frac_x,
	input  wire [2:0]  chroma_frac_y,
	output wire        chroma_busy,
	output wire        chroma_done,
	input  wire [5:0]  chroma_pred_rd_idx,
	output wire [7:0]  chroma_pred_u_rd_data,
	output wire [7:0]  chroma_pred_v_rd_data
);
	// pred_head is an unused observability port; tie read-side unused.
	wire [7:0] luma_pred_head [0:15];

	h264_mc_luma_qpel u_luma (
		.clk(clk),
		.reset(reset),
		.win_wr(luma_win_wr),
		.win_addr(luma_win_addr),
		.win_data(luma_win_data),
		.start(luma_start),
		.frac_x(luma_frac_x),
		.frac_y(luma_frac_y),
		.busy(luma_busy),
		.done(luma_done),
		.pred_rd_idx(luma_pred_rd_idx),
		.pred_rd_data(luma_pred_rd_data),
		.pred_head(luma_pred_head)
	);

	h264_mc_chroma_epel u_chroma (
		.clk(clk),
		.reset(reset),
		.win_u_wr(chroma_win_u_wr),
		.win_v_wr(chroma_win_v_wr),
		.win_addr(chroma_win_addr),
		.win_data(chroma_win_data),
		.start(chroma_start),
		.frac_x(chroma_frac_x),
		.frac_y(chroma_frac_y),
		.busy(chroma_busy),
		.done(chroma_done),
		.pred_rd_idx(chroma_pred_rd_idx),
		.pred_u_rd_data(chroma_pred_u_rd_data),
		.pred_v_rd_data(chroma_pred_v_rd_data)
	);
endmodule

`default_nettype wire
