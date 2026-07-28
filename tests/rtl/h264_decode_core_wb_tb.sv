// Testbench wrapper for h264_decode_core product DPB writeback.
`default_nettype none

module h264_decode_core_wb_tb #(
	parameter int FRAME_W = 64,
	parameter int FRAME_H = 32
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_start,
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
	output wire        error
);
	wire [7:0] rbsp_byte [0:63];
	wire [3:0] intra4x4_modes [0:15];
	wire signed [15:0] luma4x4_coeff_zigzag [0:15];
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
			assign luma4x4_coeff_zigzag[zi] = 16'sd0;
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
		.FRAME_H(FRAME_H)
	) dut (
		.clk(clk),
		.reset(reset),
		.slice_start(slice_start),
		.slice_is_idr(1'b1),
		.slice_is_i(1'b1),
		.slice_qp_y(6'd26),
		.first_mb_in_slice(16'd0),
		.mb_width(MB_WIDTH_PARAM),
		.mb_height(MB_HEIGHT_PARAM),
		.pps_chroma_qp_index_offset(5'sd0),
		.rbsp_byte(rbsp_byte),
		.rbsp_window_base(16'd0),
		.rbsp_request_offset(rbsp_request_offset),
		.rbsp_request_valid(rbsp_request_valid),
		.mb_type_valid(1'b0),
		.mb_type(5'd0),
		.mb_skip(1'b0),
		.intra4x4_modes(intra4x4_modes),
		.intra16x16_mode(2'd0),
		.chroma_pred_mode(2'd0),
		.cbp_luma(4'hf),
		.cbp_chroma(2'd2),
		.mb_qp_delta(6'sd0),
		.mb_residual_bit_offset(16'd0),
		.luma4x4_valid(1'b0),
		.luma4x4_idx(4'd0),
		.luma4x4_qp(6'd26),
		.luma4x4_total_coeff(5'd0),
		.luma4x4_trailing_ones(2'd0),
		.luma4x4_coeff_zigzag(luma4x4_coeff_zigzag),
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
		.dpb_rd_stall(1'b0),
		.dpb_ref_swap(),
		.frame_done(frame_done),
		.frame_mb_count(frame_mb_count),
		.busy(busy),
		.decode_state(decode_state),
		.current_mb_addr(current_mb_addr),
		.error(error)
	);

	(* keep = 1 *) wire _keep_unused = dpb_rd_en | |dpb_rd_addr | |rbsp_request_offset |
	                                   rbsp_request_valid;
endmodule

`default_nettype wire
