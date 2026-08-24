`default_nettype none
module h264_cabac_residual_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        slice_start,
	input  wire [1:0]  slice_type,
	input  wire [1:0]  cabac_init_idc,
	input  wire [5:0]  slice_qp_y,
	input  wire        bit_valid,
	input  wire        bit_in,
	output wire        bit_ready,
	output wire        init_busy,
	output wire        init_done,
	output wire        primed,
	input  wire        res_start,
	input  wire [2:0]  cat,
	input  wire        cbf_nA,
	input  wire        cbf_nB,
	input  wire [4:0]  max_coeff,
	output wire        dec_stall,
	output wire        res_done,
	output wire        res_ok,
	output wire signed [15:0] coeff [0:15],
	output wire [4:0]  total_coeff,
	output wire        dec_req,
	output wire [8:0]  dbg_range,
	output wire [8:0]  dbg_offset,
	output wire [4:0]  dbg_fifo_count
);
	wire dec_valid, dec_bin;
	wire [8:0] ctx_idx;
	wire bypass, terminate;
	h264_cabac u_cabac (
		.clk(clk), .reset(reset),
		.slice_start(slice_start),
		.slice_type(slice_type),
		.cabac_init_idc(cabac_init_idc),
		.slice_qp_y(slice_qp_y),
		.bit_valid(bit_valid),
		.bit_in(bit_in),
		.bit_ready(bit_ready),
		.init_busy(init_busy),
		.init_done(init_done),
		.primed(primed),
		.dec_req(dec_req),
		.ctx_idx(ctx_idx),
		.bypass(bypass),
		.terminate(terminate),
		.dec_valid(dec_valid),
		.dec_bin(dec_bin),
		.dec_stall(dec_stall),
		.dbg_range(dbg_range),
		.dbg_offset(dbg_offset),
		.dbg_fifo_count(dbg_fifo_count)
	);
	h264_cabac_residual_4x4 u_res (
		.clk(clk), .reset(reset),
		.start(res_start),
		.cat(cat),
		.cbf_nA(cbf_nA),
		.cbf_nB(cbf_nB),
		.max_coeff(max_coeff),
		.skip_cbf(1'b0),
		.dec_req(dec_req),
		.ctx_idx(ctx_idx),
		.bypass(bypass),
		.terminate(terminate),
		.dec_valid(dec_valid),
		.dec_bin(dec_bin),
		.primed(primed),
		.init_busy(init_busy),
		.done(res_done),
		.ok(res_ok),
		.coeff(coeff),
		.total_coeff(total_coeff)
	);
endmodule
`default_nettype wire
