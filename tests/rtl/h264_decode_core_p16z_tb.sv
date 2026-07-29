// Testbench wrapper for h264_decode_core P16x16 zero-MV product reconstruction.
`default_nettype none

module h264_decode_core_p16z_tb #(
	parameter int FRAME_W = 64,
	parameter int FRAME_H = 32
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_start,
	input  wire [15:0] first_mb_in_slice,
	input  wire        mb_type_valid,
	input  wire [4:0]  mb_type,
	input  wire        mb_skip,
	input  wire [15:0] mb_residual_bit_offset,
	input  wire [3:0]  cbp_luma,
	input  wire [1:0]  cbp_chroma,
	input  wire        p16_zero_mv_valid,
	input  wire [7:0]  p16_mb_x,
	input  wire [7:0]  p16_mb_y,
	input  wire        p16_mb_is_ref,
	input  wire [31:0] dpb_ref_base,
	input  wire [31:0] dpb_write_base,
	input  wire signed [15:0] p16_mv_x_qpel,
	input  wire signed [15:0] p16_mv_y_qpel,
	input  wire signed [15:0] p16_mvd_x_qpel,
	input  wire signed [15:0] p16_mvd_y_qpel,
	input  wire [1:0]  p16_ref_idx_l0,
	input  wire signed [15:0] p16_residual_y [0:255],
	input  wire signed [15:0] p16_residual_u [0:63],
	input  wire signed [15:0] p16_residual_v [0:63],
	input  wire [7:0]  rbsp_byte_in [0:63],
	input  wire [15:0] rbsp_window_base,
	input  wire [7:0]  dpb_rd_data,
	input  wire        dpb_rd_valid,

	output wire        dpb_rd_en,
	output wire [31:0] dpb_rd_addr,
	output wire        dpb_wr_en,
	output wire [31:0] dpb_wr_addr,
	output wire [7:0]  dpb_wr_data,
	output wire        frame_done,
	output wire [15:0] frame_mb_count,
	output wire [15:0] rbsp_request_offset,
	output wire        rbsp_request_valid,
	output wire        busy,
	output wire [7:0]  decode_state,
	output wire [15:0] current_mb_addr,
	output wire        error
);
	wire [3:0] intra4x4_modes [0:15];
	wire signed [15:0] luma4x4_coeff_zigzag [0:15];
	wire [7:0] recon_y [0:255];
	wire [7:0] recon_u [0:63];
	wire [7:0] recon_v [0:63];
	genvar zi;
	generate
		for (zi = 0; zi < 64; zi = zi + 1) begin : gen_zero64
			assign recon_u[zi] = 8'd0;
			assign recon_v[zi] = 8'd0;
		end
		for (zi = 0; zi < 16; zi = zi + 1) begin : gen_i4_zero
			assign intra4x4_modes[zi] = 4'd0;
			assign luma4x4_coeff_zigzag[zi] = 16'sd0;
		end
		for (zi = 0; zi < 256; zi = zi + 1) begin : gen_y_zero
			assign recon_y[zi] = 8'd0;
		end
	endgenerate

	localparam [7:0] MB_WIDTH_PARAM = 8'((FRAME_W + 15) / 16);
	localparam [7:0] MB_HEIGHT_PARAM = 8'((FRAME_H + 15) / 16);

	wire signed [15:0] tb_part_mvd_x [0:15];
	wire signed [15:0] tb_part_mvd_y [0:15];
	genvar tb_pi;
	generate
		for (tb_pi = 0; tb_pi < 16; tb_pi = tb_pi + 1) begin : g_tb_part_mvd
			assign tb_part_mvd_x[tb_pi] = 16'sd0;
			assign tb_part_mvd_y[tb_pi] = 16'sd0;
		end
	endgenerate

	h264_decode_core #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H)
	) dut (
		.clk(clk),
		.reset(reset),
		.slice_start(slice_start),
		.slice_is_idr(1'b0),
		.slice_is_i(1'b0),
		.slice_qp_y(6'd26),
		.first_mb_in_slice(first_mb_in_slice),
		.mb_width(MB_WIDTH_PARAM),
		.mb_height(MB_HEIGHT_PARAM),
		.pps_chroma_qp_index_offset(5'sd0),
		.rbsp_byte(rbsp_byte_in),
		.rbsp_window_base(rbsp_window_base),
		.rbsp_request_offset(rbsp_request_offset),
		.rbsp_request_valid(rbsp_request_valid),
		.mb_type_valid(mb_type_valid),
		.mb_type(mb_type),
		.mb_skip(mb_skip),
		.mb_intra(1'b0),
		.intra4x4_modes(intra4x4_modes),
		.intra16x16_mode(2'd0),
		.chroma_pred_mode(2'd0),
		.cbp_luma(cbp_luma),
		.cbp_chroma(cbp_chroma),
		.mb_qp_delta(6'sd0),
		.mb_residual_bit_offset(mb_residual_bit_offset),
		.luma4x4_valid(1'b0),
		.luma4x4_idx(4'd0),
		.luma4x4_qp(6'd26),
		.luma4x4_total_coeff(5'd0),
		.luma4x4_trailing_ones(2'd0),
		.luma4x4_coeff_zigzag(luma4x4_coeff_zigzag),
		.intra_chroma_residual_valid(1'b1),
		.intra_chroma_residual_u(p16_residual_u),
		.intra_chroma_residual_v(p16_residual_v),
		.mv_x_qpel(p16_mv_x_qpel),
		.mv_y_qpel(p16_mv_y_qpel),
		.part_mode(3'd0),
		.part_idx(2'd0),
		.mvd_x_qpel(p16_mvd_x_qpel),
		.mvd_y_qpel(p16_mvd_y_qpel),
		.ref_idx_l0(p16_ref_idx_l0),
		.num_ref_idx_l0_active(8'd1),
		.part_sub_mb_types(8'd0),
		.part_ref_idx_l0(8'd0),
		.part_mvd_valid(16'd0),
		.part_mvd_x(tb_part_mvd_x),
		.part_mvd_y(tb_part_mvd_y),
		.recon_mb_valid(1'b0),
		.recon_mb_x(8'd0),
		.recon_mb_y(8'd0),
		.recon_mb_is_ref(1'b0),
		.dpb_write_base(dpb_write_base),
		.recon_y(recon_y),
		.recon_u(recon_u),
		.recon_v(recon_v),
		.p16_zero_mv_valid(p16_zero_mv_valid),
		.p16_mb_x(p16_mb_x),
		.p16_mb_y(p16_mb_y),
		.p16_mb_is_ref(p16_mb_is_ref),
		.dpb_ref_base(dpb_ref_base),
		.p16_residual_y(p16_residual_y),
		.p16_residual_u(p16_residual_u),
		.p16_residual_v(p16_residual_v),
		.dpb_wr_en(dpb_wr_en),
		.dpb_wr_addr(dpb_wr_addr),
		.dpb_wr_data(dpb_wr_data),
		.dpb_rd_en(dpb_rd_en),
		.dpb_rd_addr(dpb_rd_addr),
		.dpb_rd_data(dpb_rd_data),
		.dpb_rd_valid(dpb_rd_valid),
		.frame_done(frame_done),
		.frame_mb_count(frame_mb_count),
		.busy(busy),
		.decode_state(decode_state),
		.current_mb_addr(current_mb_addr),
		.error(error)
	);

	(* keep = 1 *) wire _keep_unused = rbsp_request_valid;
endmodule

`default_nettype wire

