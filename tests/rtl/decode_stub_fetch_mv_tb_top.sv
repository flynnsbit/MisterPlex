// Product-path gate: decode_stub must drive DPB fetch from MVP+mvd (not hardwired 0).
// FAULT_FORCE_ZERO_FETCH_MV is the mutation twin.
`default_nettype none

module decode_stub_fetch_mv_tb #(
	parameter bit FAULT_FORCE_ZERO_FETCH_MV = 1'b0
)(
	input  wire        clk,
	input  wire        reset,

	input  wire        idr_pulse,
	input  wire        p_pulse,
	input  wire        is_p_slice,
	input  wire        residual_valid,
	input  wire        slice_valid,
	input  wire        has_mb_type,
	input  wire        first_mb_p_skip,
	input  wire [2:0]  first_mb_part_mode,
	input  wire signed [15:0] first_mb_mvd_x,
	input  wire signed [15:0] first_mb_mvd_y,

	output wire        busy,
	output wire [15:0] frames_out,
	output wire [7:0]  recon_sig,
	output wire        recon_valid,
	output wire signed [15:0] product_fetch_mv_x,
	output wire signed [15:0] product_fetch_mv_y,
	output wire signed [15:0] product_luma_origin_x,
	output wire signed [15:0] product_luma_origin_y
);
	wire [7:0] recon_dbg;
	wire recon_dbg_valid;
	wire wr_en;
	wire [15:0] wr_pixel;
	wire wr_reset_ptr;
	wire swap_req;

	// Single-MB frame: IDR fill is 385 beats; origin check is unambiguous.
	localparam int W = 16;
	localparam int H = 16;

	reg [7:0] nal_type_r;
	reg       vcl_pulse_r;
	always @* begin
		nal_type_r = 8'h01;
		vcl_pulse_r = 1'b0;
		if (idr_pulse) begin
			nal_type_r = 8'h65;
			vcl_pulse_r = 1'b1;
		end else if (p_pulse) begin
			nal_type_r = 8'h01;
			vcl_pulse_r = 1'b1;
		end
	end

	wire signed [15:0] zero_coeff [0:15];
	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_z
			assign zero_coeff[gi] = 16'sd0;
		end
	endgenerate

	decode_stub #(
		.WIDTH(W),
		.HEIGHT(H),
		.ENABLE_DPB_REF_SEAM(1'b1),
		.FAULT_FORCE_ZERO_FETCH_MV(FAULT_FORCE_ZERO_FETCH_MV)
	) dut (
		.clk(clk),
		.reset(reset),
		.vcl_pulse(vcl_pulse_r),
		.last_nal_type(nal_type_r),
		.nalu_count(16'd1),
		.idr_count(8'd1),
		.has_idr(1'b1),
		.sps_valid(1'b1),
		.mb_w(8'd1),
		.mb_h(8'd1),
		.slice_type(is_p_slice ? 8'd0 : 8'd7),
		.slice_is_i(is_p_slice ? 1'b0 : 1'b1),
		.slice_valid(slice_valid),
		.first_mb_addr(16'd0),
		.has_mb_type(has_mb_type),
		.first_mb_p_skip(first_mb_p_skip),
		.first_mb_part_mode(first_mb_part_mode),
		.first_mb_part_count(3'd1),
		.first_mb_uses_sub_mb(1'b0),
		.first_mb_intra(is_p_slice ? 1'b0 : 1'b1),
				.trav_mb_valid(1'b0),
		.trav_mb_ready(),
		.trav_mb_addr(16'd0),
		.trav_mb_x(8'd0),
		.trav_mb_y(8'd0),
		.trav_mb_skip(1'b0),
		.trav_part_mode(3'd0),
		.trav_part_count(3'd0),
		.trav_uses_sub_mb(1'b0),
		.trav_intra(1'b0),
		.trav_slice_done(1'b0),
		.i_res_blk_valid(1'b0),
		.i_res_blk_ready(),
		.i_res_blk_mb_addr(16'd0),
		.i_res_blk_mb_x(8'd0),
		.i_res_blk_mb_y(8'd0),
		.i_res_blk_idx(5'd0),
		.i_res_blk_is_i16(1'b0),
		.i_res_blk_is_luma(1'b0),
		.i_res_blk_qp(6'd0),
		.i_res_blk_max_coeff(5'd16),
		.i_res_blk_coeff(zero_coeff),
		.i_res_mb_end(1'b0),
		.i_res_mb_end_addr(16'd0),
		.first_mb_mvd_x(first_mb_mvd_x),
		.first_mb_mvd_y(first_mb_mvd_y),
		.residual_ok(1'b1),
		.residual_tc(5'd0),
		.residual_dc(8'sd0),
		.residual_valid(residual_valid),
		.slice_qp(6'd26),
		.residual_coeff(zero_coeff),
		.recon_sig(recon_sig),
		.recon_dbg(recon_dbg),
		.recon_dbg_valid(recon_dbg_valid),
		.recon_valid(recon_valid),
		.product_fetch_mv_x(product_fetch_mv_x),
		.product_fetch_mv_y(product_fetch_mv_y),
		.product_luma_origin_x(product_luma_origin_x),
		.product_luma_origin_y(product_luma_origin_y),
		.wr_en(wr_en),
		.wr_pixel(wr_pixel),
		.wr_reset_ptr(wr_reset_ptr),
		.swap_req(swap_req),
		.busy(busy),
		.frames_out(frames_out)
	);
endmodule

`default_nettype wire
