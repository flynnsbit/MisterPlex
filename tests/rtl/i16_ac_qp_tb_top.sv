// I16 AC (max_coeff=15, skip_dc) + mb_qp_delta mod-52 wrap.
// Proves residual path pieces used by product I_16x16 after parser fixes.
`timescale 1ns/1ps
module i16_ac_qp_tb_top (
	input  wire               clk,
	input  wire               rst,
	input  wire [5:0]         qp_prev,
	input  wire signed [7:0]  qp_delta,
	output wire [5:0]         qp_y,
	input  wire               iq_start,
	input  wire signed [15:0] iq_coeff [0:15],
	input  wire [5:0]         iq_qp,
	input  wire [4:0]         iq_max_coeff,
	input  wire               iq_skip_dc,
	input  wire               iq_dc_override,
	input  wire signed [28:0] iq_dc_value,
	output wire               iq_done,
	output wire signed [28:0] iq_resid [0:15],
	output wire signed [28:0] par_resid [0:15]
);
	h264_qp_y_add_delta u_qp (
		.prev_qp(qp_prev),
		.mb_qp_delta(qp_delta),
		.qp_y(qp_y)
	);

	h264_iq_idct_seq u_seq (
		.clk(clk),
		.reset(rst),
		.start(iq_start),
		.coeff(iq_coeff),
		.qp(iq_qp),
		.max_coeff(iq_max_coeff),
		.skip_dc(iq_skip_dc),
		.dc_override(iq_dc_override),
		.dc_value(iq_dc_value),
		.residual(iq_resid),
		.done(iq_done)
	);

	wire signed [28:0] par_d [0:15];
	h264_dequant4x4_flex u_par_dq (
		.coeff(iq_coeff),
		.qp(iq_qp),
		.max_coeff(iq_max_coeff),
		.skip_dc(iq_skip_dc),
		.dc_override(iq_dc_override),
		.dc_value(iq_dc_value),
		.dequant(par_d)
	);
	h264_idct4x4 u_par_idct (
		.dequant(par_d),
		.residual(par_resid)
	);
endmodule
