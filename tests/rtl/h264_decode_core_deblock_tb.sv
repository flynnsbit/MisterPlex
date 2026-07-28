// Testbench wrapper for the in-loop deblocking stage of h264_decode_core.
//
// Two things are proven here that the standalone filter gate cannot prove:
//   1. the samples the *core* writes to the DPB are POST-deblock, and
//   2. the PRE/POST + DPB promotion ordering contract still holds once a real
//      filter sits in the writeback path.
//
// The ordering signals are read out by hierarchical reference so the contract
// is observed on the product wires themselves, not on a testbench copy.
`default_nettype none

module h264_decode_core_deblock_tb #(
	parameter int FRAME_W = 64,
	parameter int FRAME_H = 64
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_start,
	input  wire        slice_is_idr,
	input  wire        slice_is_i,
	input  wire [5:0]  slice_qp_y,
	input  wire [1:0]  slice_disable_deblocking_filter_idc,
	input  wire signed [4:0] slice_alpha_c0_offset,
	input  wire signed [4:0] slice_beta_offset,
	input  wire signed [4:0] pps_chroma_qp_index_offset,
	input  wire [3:0]  cbp_luma,
	input  wire [4:0]  mb_type,
	input  wire        mb_skip,
	input  wire        mb_type_valid,
	input  wire        recon_mb_valid,
	input  wire [7:0]  recon_mb_x,
	input  wire [7:0]  recon_mb_y,
	input  wire        recon_mb_is_ref,
	input  wire [31:0] dpb_write_base,
	input  wire [7:0]  recon_y [0:255],
	input  wire [7:0]  recon_u [0:63],
	input  wire [7:0]  recon_v [0:63],

	output wire        dpb_wr_en,
	output wire [31:0] dpb_wr_addr,
	output wire [7:0]  dpb_wr_data,
	output wire        frame_done,
	output wire [15:0] frame_mb_count,
	output wire        busy,
	output wire [7:0]  decode_state,
	output wire [15:0] current_mb_addr,
	output wire        error,

	// ── ordering-contract observability (hierarchical, product wires) ──
	output wire        obs_filtered_sample_valid,
	output wire        obs_filtered_mb_valid,
	output wire        obs_wb_valid,
	output wire        obs_frame_boundary,
	output wire        obs_ref_ready_pulse,
	output wire        obs_ref_pending,
	output wire        obs_commit_order_error,
	output wire [15:0] obs_luma_modified,
	output wire [15:0] obs_chroma_modified,
	output wire [5:0]  obs_last_chroma_qp,
	output wire        obs_filter_pipe_error
);
	wire [7:0] rbsp_byte [0:63];
	wire [3:0] intra4x4_modes [0:15];
	wire signed [15:0] p16_residual_y [0:255];
	wire signed [15:0] p16_residual_u [0:63];
	wire signed [15:0] p16_residual_v [0:63];
	genvar zi;
	generate
		for (zi = 0; zi < 64; zi = zi + 1) begin : gen_rbsp_zero
			assign rbsp_byte[zi] = 8'd0;
			assign p16_residual_u[zi] = 16'sd0;
			assign p16_residual_v[zi] = 16'sd0;
		end
		for (zi = 0; zi < 16; zi = zi + 1) begin : gen_i4_zero
			assign intra4x4_modes[zi] = 4'd0;
		end
		for (zi = 0; zi < 256; zi = zi + 1) begin : gen_p16_y_zero
			assign p16_residual_y[zi] = 16'sd0;
		end
	endgenerate

	wire dpb_rd_en;
	wire [31:0] dpb_rd_addr;
	wire [15:0] rbsp_request_offset;
	wire rbsp_request_valid;
	localparam [7:0] MB_WIDTH_PARAM = 8'((FRAME_W + 15) / 16);
	localparam [7:0] MB_HEIGHT_PARAM = 8'((FRAME_H + 15) / 16);

	h264_decode_core #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.DEBLOCK_IN_LOOP(1'b1)
	) dut (
		.clk(clk),
		.reset(reset),
		.slice_start(slice_start),
		.slice_is_idr(slice_is_idr),
		.slice_is_i(slice_is_i),
		.slice_qp_y(slice_qp_y),
		.first_mb_in_slice(16'd0),
		.mb_width(MB_WIDTH_PARAM),
		.mb_height(MB_HEIGHT_PARAM),
		.pps_chroma_qp_index_offset(pps_chroma_qp_index_offset),
		.slice_disable_deblocking_filter_idc(slice_disable_deblocking_filter_idc),
		.slice_alpha_c0_offset(slice_alpha_c0_offset),
		.slice_beta_offset(slice_beta_offset),
		.rbsp_byte(rbsp_byte),
		.rbsp_window_base(16'd0),
		.rbsp_request_offset(rbsp_request_offset),
		.rbsp_request_valid(rbsp_request_valid),
		.mb_type_valid(mb_type_valid),
		.mb_type(mb_type),
		.mb_skip(mb_skip),
		.intra4x4_modes(intra4x4_modes),
		.intra16x16_mode(2'd0),
		.chroma_pred_mode(2'd0),
		.cbp_luma(cbp_luma),
		.cbp_chroma(2'd2),
		.mb_qp_delta(6'sd0),
		.mb_residual_bit_offset(16'd0),
		.mv_x_qpel(16'sd0),
		.mv_y_qpel(16'sd0),
		.part_mode(3'd0),
		.part_idx(2'd0),
		.mvd_x_qpel(16'sd0),
		.mvd_y_qpel(16'sd0),
		.ref_idx_l0(2'd0),
		.recon_mb_valid(recon_mb_valid),
		.recon_mb_x(recon_mb_x),
		.recon_mb_y(recon_mb_y),
		.recon_mb_is_ref(recon_mb_is_ref),
		.dpb_write_base(dpb_write_base),
		.recon_y(recon_y),
		.recon_u(recon_u),
		.recon_v(recon_v),
		.p16_zero_mv_valid(1'b0),
		.p16_mb_x(8'd0),
		.p16_mb_y(8'd0),
		.p16_mb_is_ref(1'b0),
		.dpb_ref_base(32'd0),
		.p16_residual_y(p16_residual_y),
		.p16_residual_u(p16_residual_u),
		.p16_residual_v(p16_residual_v),
		.dpb_wr_en(dpb_wr_en),
		.dpb_wr_addr(dpb_wr_addr),
		.dpb_wr_data(dpb_wr_data),
		.dpb_rd_en(dpb_rd_en),
		.dpb_rd_addr(dpb_rd_addr),
		.dpb_rd_data(8'd0),
		.dpb_rd_valid(1'b0),
		.frame_done(frame_done),
		.frame_mb_count(frame_mb_count),
		.busy(busy),
		.decode_state(decode_state),
		.current_mb_addr(current_mb_addr),
		.error(error)
	);

	assign obs_filtered_sample_valid = dut.deblock_filtered_sample_valid;
	assign obs_filtered_mb_valid     = dut.deblock_filtered_mb_valid;
	assign obs_wb_valid              = dut.deblock_wb_valid;
	assign obs_frame_boundary        = dut.deblock_frame_boundary;
	assign obs_ref_ready_pulse       = dut.deblock_ref_ready_pulse;
	assign obs_ref_pending           = dut.u_core_deblock_wb.ref_pending;
	assign obs_commit_order_error    = dut.deblock_commit_order_error;
	assign obs_luma_modified         = dut.db_luma_modified;
	assign obs_chroma_modified       = dut.db_chroma_modified;
	assign obs_last_chroma_qp        = dut.db_last_chroma_qp;
	assign obs_filter_pipe_error     = dut.db_pipe_error;

	(* keep = 1 *) wire _keep_unused = dpb_rd_en | |dpb_rd_addr | |rbsp_request_offset |
	                                   rbsp_request_valid;
endmodule

`default_nettype wire
