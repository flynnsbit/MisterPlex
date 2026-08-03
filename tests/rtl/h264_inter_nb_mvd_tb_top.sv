// Testbench top: product h264_inter_nb_ctx + h264_mv_pred_part.
// Faults live only in the TB wrapper (EXPECTED_RED twins).
`default_nettype none

module h264_inter_nb_mvd_tb #(
	parameter int MB_WIDTH_MAX = 40,
	parameter bit FAULT_SWAP_AB = 1'b0,
	parameter bit FAULT_DROP_C_FALLBACK = 1'b0
) (
	input  wire               clk,
	input  wire               reset,
	input  wire [7:0]         mb_x,
	input  wire [7:0]         mb_y,
	input  wire [7:0]         mb_width,
	input  wire               mb_start,
	input  wire [2:0]         part_mode,
	input  wire [1:0]         part_idx,
	input  wire               p_skip,
	input  wire signed [15:0] mvd_x,
	input  wire signed [15:0] mvd_y,
	input  wire               commit,
	input  wire               is_inter,
	input  wire signed [15:0] commit_mv_x,
	input  wire signed [15:0] commit_mv_y,
	input  wire [1:0]         ref_idx,

	output wire               avail_a,
	output wire               avail_b,
	output wire               avail_c,
	output wire               avail_d,
	output wire signed [15:0] pred_x,
	output wire signed [15:0] pred_y,
	output wire signed [15:0] mv_x,
	output wire signed [15:0] mv_y,
	output wire               skip_zero
);
	wire a0, b0, c0, d0;
	wire signed [15:0] ax, ay, bx, by, cx, cy, dx, dy;
	wire [1:0] ra, rb, rc, rd;

	h264_inter_nb_ctx #(.MB_WIDTH_MAX(MB_WIDTH_MAX)) u_nb (
		.clk(clk), .reset(reset),
		.mb_x(mb_x), .mb_y(mb_y), .mb_width(mb_width), .mb_start(mb_start),
		.part_mode(part_mode), .part_idx(part_idx),
		.commit(commit), .is_inter(is_inter),
		.mv_x(commit_mv_x), .mv_y(commit_mv_y), .ref_idx(ref_idx),
		.avail_a(a0), .avail_b(b0), .avail_c(c0), .avail_d(d0),
		.mv_a_x(ax), .mv_a_y(ay), .mv_b_x(bx), .mv_b_y(by),
		.mv_c_x(cx), .mv_c_y(cy), .mv_d_x(dx), .mv_d_y(dy),
		.ref_a(ra), .ref_b(rb), .ref_c(rc), .ref_d(rd)
	);

	// FAULT_SWAP_AB: swap left/above neighbour ports into MVP.
	wire avail_a_u = FAULT_SWAP_AB ? b0 : a0;
	wire avail_b_u = FAULT_SWAP_AB ? a0 : b0;
	wire signed [15:0] mv_a_x_u = FAULT_SWAP_AB ? bx : ax;
	wire signed [15:0] mv_a_y_u = FAULT_SWAP_AB ? by : ay;
	wire signed [15:0] mv_b_x_u = FAULT_SWAP_AB ? ax : bx;
	wire signed [15:0] mv_b_y_u = FAULT_SWAP_AB ? ay : by;

	// FAULT_DROP_C_FALLBACK: force C missing and D missing so median loses C→D.
	wire avail_c_u = FAULT_DROP_C_FALLBACK ? 1'b0 : c0;
	wire avail_d_u = FAULT_DROP_C_FALLBACK ? 1'b0 : d0;

	assign avail_a = avail_a_u;
	assign avail_b = avail_b_u;
	assign avail_c = avail_c_u;
	assign avail_d = avail_d_u;

	h264_mv_pred_part u_mvp (
		.part_mode(part_mode), .part_idx(part_idx),
		.avail_a(avail_a_u), .avail_b(avail_b_u),
		.avail_c(avail_c_u), .avail_d(avail_d_u),
		.mv_a_x(mv_a_x_u), .mv_a_y(mv_a_y_u),
		.mv_b_x(mv_b_x_u), .mv_b_y(mv_b_y_u),
		.mv_c_x(cx), .mv_c_y(cy),
		.mv_d_x(dx), .mv_d_y(dy),
		.mvd_x(mvd_x), .mvd_y(mvd_y), .p_skip(p_skip),
		.pred_x(pred_x), .pred_y(pred_y),
		.mv_x(mv_x), .mv_y(mv_y), .skip_zero(skip_zero)
	);
endmodule

`default_nettype wire
