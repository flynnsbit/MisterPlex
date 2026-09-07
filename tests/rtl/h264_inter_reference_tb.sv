// Leaf proof: synthetic filtered samples enter the real DPB write interface.
// This is not a bitstream decoder or a prefilled-reference composed oracle.
`default_nettype none
module h264_inter_reference_tb (
	input wire clk, reset, idr_start, frame_start, frame_abort, frame_done,
	input wire [15:0] frame_width, frame_height,
	output wire ref_ready,
	output wire frame_error, frame_promoted,
	output wire [31:0] current_base, reference_base,
	output wire [15:0] reference_width, reference_height,
	input wire filtered_sample_valid,
	input wire [7:0] filtered_mb_x, filtered_mb_y,
	input wire [1:0] filtered_plane,
	input wire [7:0] filtered_sample_idx, filtered_sample,
	output wire filtered_sample_ready,
	output wire mem_we,
	output wire [31:0] mem_waddr,
	output wire [7:0] mem_wdata,
	input wire mem_wready, mem_wdrained,
	input wire fetch_start,
	input wire [7:0] fetch_mb_x, fetch_mb_y,
	input wire [2:0] fetch_part_mode,
	input wire [1:0] fetch_part_idx,
	input wire [4:0] fetch_part_w, fetch_part_h,
	input wire signed [15:0] fetch_mv_x_qpel, fetch_mv_y_qpel,
	output wire fetch_busy, fetch_done, fetch_error_no_ref,
	output wire [1:0] luma_frac_x, luma_frac_y,
	output wire [2:0] chroma_frac_x, chroma_frac_y,
	output wire signed [15:0] luma_origin_x, luma_origin_y, chroma_origin_x, chroma_origin_y,
	output wire mem_rd,
	output wire [31:0] mem_raddr,
	input wire mem_rready,
	input wire [7:0] mem_rdata,
	input wire mem_rvalid,
	output wire luma_window_valid,
	output wire [8:0] luma_window_idx,
	output wire [7:0] luma_window_sample,
	output wire chroma_u_window_valid, chroma_v_window_valid,
	output wire [6:0] chroma_window_idx,
	output wire [7:0] chroma_window_sample,
	output wire bank_sel,
	input wire mc_start,
	output wire mc_done,
	output wire [7:0] pred_y [0:255], pred_u [0:63], pred_v [0:63],
	output reg [7:0] win_y [0:440], win_u [0:80], win_v [0:80],

	input wire avail_a, avail_b, avail_c, avail_d, intra_a, intra_b, intra_c, intra_d,
	input wire signed [15:0] mv_a_x, mv_a_y, mv_b_x, mv_b_y, mv_c_x, mv_c_y, mv_d_x, mv_d_y,
	input wire signed [15:0] mvd_x, mvd_y,
	input wire p_skip,
	output wire signed [15:0] mv_pred_x, mv_pred_y, mv_x, mv_y,
	output wire skip_zero,

	input wire is_chroma, disable_all, slice_boundary_blocked, mb_boundary,
	input wire p_intra, q_intra, p_nonzero, q_nonzero,
	input wire [1:0] p_ref, q_ref,
	input wire signed [11:0] p_mvx, p_mvy, q_mvx, q_mvy,
	input wire [5:0] qp_p, qp_q,
	input wire signed [4:0] chroma_qp_index_offset, alpha_off, beta_off,
	input wire [7:0] p3_in [0:3], p2_in [0:3], p1_in [0:3], p0_in [0:3],
	input wire [7:0] q0_in [0:3], q1_in [0:3], q2_in [0:3], q3_in [0:3],
	output wire [2:0] bs,
	output wire unsupported_ref,
	output wire [5:0] qp_avg,
	output wire [7:0] p2_out [0:3], p1_out [0:3], p0_out [0:3],
	output wire [7:0] q0_out [0:3], q1_out [0:3], q2_out [0:3],
	output wire [7:0] alpha_dbg, beta_dbg,
	output wire [5:0] tc0_dbg
);
	h264_dpb_one_ref #(.FRAME_W(320), .FRAME_H(240), .BANK0_BASE(0), .BANK1_BASE(115200)) u_dpb (.*);
	assign bank_sel = current_base != 0;
	always @(posedge clk) begin
		if (luma_window_valid) win_y[luma_window_idx] <= luma_window_sample;
		if (chroma_u_window_valid) win_u[chroma_window_idx] <= chroma_window_sample;
		if (chroma_v_window_valid) win_v[chroma_window_idx] <= chroma_window_sample;
	end
	h264_inter_mc_16x16 u_mc (
		.clk(clk), .reset(reset), .start(mc_start),
		.luma_ref_win(win_y), .chroma_u_ref_win(win_u), .chroma_v_ref_win(win_v),
		.luma_frac_x(luma_frac_x), .luma_frac_y(luma_frac_y),
		.chroma_frac_x(chroma_frac_x), .chroma_frac_y(chroma_frac_y),
		.pred_y(pred_y), .pred_u(pred_u), .pred_v(pred_v), .done(mc_done)
	);
	h264_mv_pred_16x16 u_mv (.pred_x(mv_pred_x), .pred_y(mv_pred_y), .*);
	h264_deblock_bs u_bs (.*);
	h264_deblock_qp u_qp (.*);
	h264_deblock_edge u_edge (
		.slice_alpha_c0_offset(alpha_off), .slice_beta_offset(beta_off), .*
	);
endmodule
`default_nettype wire
