// Simulation harness top for the SERIALIZED motion-compensation interpolators.
//
// Both engines were rewritten from fully-parallel port-array forms into
// resource-shared sequential datapaths (89,888 -> 441 ALUTs for the luma
// engine).  That class of rewrite preserves the algorithm and is exactly the
// class that breaks the implementation, so this top exists to EXECUTE the RTL
// rather than compare a model beside it.
//
// Flat scalar ports only: the engines' unpacked-array observability output is
// terminated here so the C++ driver sees a plain port surface.

`default_nettype none

module h264_mc_qpel_tb_top (
	input  wire        clk,
	input  wire        reset,

	// ---- luma quarter-sample engine -----------------------------------
	input  wire        l_win_wr,
	input  wire [8:0]  l_win_addr,
	input  wire [7:0]  l_win_data,
	input  wire        l_start,
	input  wire [1:0]  l_frac_x,
	input  wire [1:0]  l_frac_y,
	output wire        l_busy,
	output wire        l_done,
	input  wire [7:0]  l_pred_rd_idx,
	output wire [7:0]  l_pred_rd_data,
	output wire [7:0]  l_pred_head0,

	// ---- chroma eighth-sample engine ----------------------------------
	input  wire        c_win_u_wr,
	input  wire        c_win_v_wr,
	input  wire [6:0]  c_win_addr,
	input  wire [7:0]  c_win_data,
	input  wire        c_start,
	input  wire [2:0]  c_frac_x,
	input  wire [2:0]  c_frac_y,
	output wire        c_busy,
	output wire        c_done,
	input  wire [5:0]  c_pred_rd_idx,
	output wire [7:0]  c_pred_u_rd_data,
	output wire [7:0]  c_pred_v_rd_data
);

	wire [7:0] l_pred_head [0:15];
	assign l_pred_head0 = l_pred_head[0];

	h264_mc_luma_qpel u_luma (
		.clk(clk),
		.reset(reset),
		.win_wr(l_win_wr),
		.win_addr(l_win_addr),
		.win_data(l_win_data),
		.start(l_start),
		.frac_x(l_frac_x),
		.frac_y(l_frac_y),
		.busy(l_busy),
		.done(l_done),
		.pred_rd_idx(l_pred_rd_idx),
		.pred_rd_data(l_pred_rd_data),
		.pred_head(l_pred_head)
	);

	h264_mc_chroma_epel u_chroma (
		.clk(clk),
		.reset(reset),
		.win_u_wr(c_win_u_wr),
		.win_v_wr(c_win_v_wr),
		.win_addr(c_win_addr),
		.win_data(c_win_data),
		.start(c_start),
		.frac_x(c_frac_x),
		.frac_y(c_frac_y),
		.busy(c_busy),
		.done(c_done),
		.pred_rd_idx(c_pred_rd_idx),
		.pred_u_rd_data(c_pred_u_rd_data),
		.pred_v_rd_data(c_pred_v_rd_data)
	);

endmodule

`default_nettype wire
