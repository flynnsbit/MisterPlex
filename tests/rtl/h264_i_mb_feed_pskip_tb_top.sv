// Focused Verilator wrapper for multi-MB P walker mb_skip_run boundaries.
// Instantiates product h264_i_mb_feed (+ cavlc residual dependency).
`default_nettype none

module h264_i_mb_feed_pskip_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_go,
	input  wire [7:0]  mb_width,
	input  wire [7:0]  mb_height,
	input  wire [15:0] first_mb_in_slice,
	input  wire [5:0]  slice_qp_y,
	input  wire [7:0]  first_mb_type,
	input  wire        first_mb_p_skip,
	input  wire [15:0] first_p_skip_run,
	input  wire        first_mb_intra,
	input  wire [2:0]  first_mb_part_mode,
	input  wire [3:0]  first_cbp_luma,
	input  wire [1:0]  first_cbp_chroma,
	input  wire [15:0] first_residual_bit_offset,
	input  wire [7:0]  rbsp_byte_in [0:63],
	input  wire [15:0] rbsp_window_base,
	input  wire        rbsp_window_ready,
	input  wire [15:0] rbsp_length,
	input  wire        rbsp_complete,
	input  wire        core_busy,

	output wire [15:0] rbsp_request_offset,
	output wire        rbsp_request_valid,
	output wire        mb_type_valid,
	output wire [4:0]  mb_type,
	output wire        mb_skip,
	output wire        mb_intra,
	output wire [2:0]  part_mode,
	output wire [3:0]  cbp_luma,
	output wire [1:0]  cbp_chroma,
	output wire        busy,
	output wire        frame_feed_done,
	output wire        error,
	output wire        slice_desync,
	output wire        slice_desync_early,
	output wire        slice_desync_long,
	output wire [3:0]  slice_desync_cause,
	output wire [15:0] slice_desync_mb
);
	wire signed [15:0] first_mvd_x [0:15];
	wire signed [15:0] first_mvd_y [0:15];
	wire signed [15:0] mvd_x [0:15];
	wire signed [15:0] mvd_y [0:15];
	wire signed [15:0] luma_zz [0:15];
	wire signed [15:0] chr_u [0:63];
	wire signed [15:0] chr_v [0:63];
	wire signed [15:0] p_res_y [0:255];
	wire signed [15:0] p_res_u [0:63];
	wire signed [15:0] p_res_v [0:63];
	wire        p_res_valid;
	wire [7:0] rbsp_byte [0:63];

	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_mvd0
			assign first_mvd_x[gi] = 16'sd0;
			assign first_mvd_y[gi] = 16'sd0;
		end
		for (gi = 0; gi < 64; gi = gi + 1) begin : g_rbsp
			assign rbsp_byte[gi] = rbsp_byte_in[gi];
		end
	endgenerate

	h264_i_mb_feed #(.MB_W_MAX(40)) dut (
		.clk(clk),
		.reset(reset),
		.slice_go(slice_go),
		.slice_is_i(1'b0),
		.mb_width(mb_width),
		.mb_height(mb_height),
		.first_mb_in_slice(first_mb_in_slice),
		.slice_qp_y(slice_qp_y),
		.pps_chroma_qp_index_offset(5'sd0),
		.first_mb_type(first_mb_type),
		.first_mb_p_skip(first_mb_p_skip),
		.first_p_skip_run(first_p_skip_run),
		.first_mb_intra(first_mb_intra),
		.first_mb_part_mode(first_mb_part_mode),
		.first_sub_mb_types(8'd0),
		.first_mb_ref_idx_l0(8'd0),
		.first_mb_mvd_valid(16'd0),
		.first_mb_mvd_x(first_mvd_x),
		.first_mb_mvd_y(first_mvd_y),
		.num_ref_idx_l0_active(8'd1),
		.first_i4_pred_mode_flags(16'd0),
		.first_i4_rem_modes(48'd0),
		.first_i4_modes_present(1'b0),
		.first_chroma_pred_mode(2'd0),
		.first_cbp_luma(first_cbp_luma),
		.first_cbp_chroma(first_cbp_chroma),
		.first_residual_bit_offset(first_residual_bit_offset),
		.rbsp_byte(rbsp_byte),
		.rbsp_window_base(rbsp_window_base),
		.rbsp_window_ready(rbsp_window_ready),
		.rbsp_request_offset(rbsp_request_offset),
		.rbsp_request_valid(rbsp_request_valid),
		.rbsp_length(rbsp_length),
		.rbsp_complete(rbsp_complete),
		.core_busy(core_busy),
		.core_intra_blocks_done(5'd0),
		.mb_type_valid(mb_type_valid),
		.mb_type(mb_type),
		.mb_skip(mb_skip),
		.mb_intra(mb_intra),
		.part_mode(part_mode),
		.sub_mb_types(),
		.ref_idx_l0_packed(),
		.mvd_valid(),
		.mvd_x(mvd_x),
		.mvd_y(mvd_y),
		.i4_pred_mode_flags(),
		.i4_rem_modes(),
		.i4_modes_present(),
		.intra16x16_mode(),
		.chroma_pred_mode(),
		.cbp_luma(cbp_luma),
		.cbp_chroma(cbp_chroma),
		.mb_qp_delta(),
		.mb_qp_y(),
		.mb_residual_bit_offset(),
		.luma4x4_valid(),
		.luma4x4_idx(),
		.luma4x4_qp(),
		.luma4x4_total_coeff(),
		.luma4x4_trailing_ones(),
		.luma4x4_coeff_zigzag(luma_zz),
		.chroma_residual_u(chr_u),
		.chroma_residual_v(chr_v),
		.chroma_residual_valid(),
		.p_residual_y(p_res_y),
		.p_residual_u(p_res_u),
		.p_residual_v(p_res_v),
		.p_residual_valid(p_res_valid),
		.busy(busy),
		.frame_feed_done(frame_feed_done),
		.error(error),
		.slice_desync(slice_desync),
		.slice_desync_early(slice_desync_early),
		.slice_desync_long(slice_desync_long),
		.slice_desync_cause(slice_desync_cause),
		.slice_desync_mb(slice_desync_mb)
	);
endmodule

`default_nettype wire
