// Full-suite RTL vector top: I4x4 + iq_idct_seq vs parallel dequant/idct.
// Scaffolding only — not in files.qip / not synthesised.
`default_nettype none

module intra_full_suite_tb_top (
	input  wire        clk,
	input  wire        reset,

	// ── I4x4 (combinational) ──
	input  wire [3:0]  i4_mode,
	input  wire [7:0]  i4_a0, i4_a1, i4_a2, i4_a3,
	input  wire [7:0]  i4_a4, i4_a5, i4_a6, i4_a7,
	input  wire [7:0]  i4_l0, i4_l1, i4_l2, i4_l3,
	input  wire [7:0]  i4_tl,
	input  wire        i4_has_above,
	input  wire        i4_has_left,
	output wire [3:0]  i4_used_mode,
	output wire [7:0]  i4_p0,  i4_p1,  i4_p2,  i4_p3,
	output wire [7:0]  i4_p4,  i4_p5,  i4_p6,  i4_p7,
	output wire [7:0]  i4_p8,  i4_p9,  i4_p10, i4_p11,
	output wire [7:0]  i4_p12, i4_p13, i4_p14, i4_p15,

	// ── iq_idct_seq ──
	input  wire        iq_start,
	input  wire signed [15:0] iq_c0,  iq_c1,  iq_c2,  iq_c3,
	input  wire signed [15:0] iq_c4,  iq_c5,  iq_c6,  iq_c7,
	input  wire signed [15:0] iq_c8,  iq_c9,  iq_c10, iq_c11,
	input  wire signed [15:0] iq_c12, iq_c13, iq_c14, iq_c15,
	input  wire [5:0]  iq_qp,
	input  wire [4:0]  iq_max_coeff,
	input  wire        iq_skip_dc,
	input  wire        iq_dc_override,
	input  wire signed [28:0] iq_dc_value,
	output wire        iq_done,
	output wire signed [28:0] iq_r0,  iq_r1,  iq_r2,  iq_r3,
	output wire signed [28:0] iq_r4,  iq_r5,  iq_r6,  iq_r7,
	output wire signed [28:0] iq_r8,  iq_r9,  iq_r10, iq_r11,
	output wire signed [28:0] iq_r12, iq_r13, iq_r14, iq_r15,

	// ── parallel dequant+idct (reference RTL) ──
	output wire signed [28:0] par_r0,  par_r1,  par_r2,  par_r3,
	output wire signed [28:0] par_r4,  par_r5,  par_r6,  par_r7,
	output wire signed [28:0] par_r8,  par_r9,  par_r10, par_r11,
	output wire signed [28:0] par_r12, par_r13, par_r14, par_r15
);
	wire [7:0] i4_above [0:7];
	wire [7:0] i4_left  [0:3];
	wire [7:0] i4_pred  [0:15];
	assign i4_above[0]=i4_a0; assign i4_above[1]=i4_a1;
	assign i4_above[2]=i4_a2; assign i4_above[3]=i4_a3;
	assign i4_above[4]=i4_a4; assign i4_above[5]=i4_a5;
	assign i4_above[6]=i4_a6; assign i4_above[7]=i4_a7;
	assign i4_left[0]=i4_l0; assign i4_left[1]=i4_l1;
	assign i4_left[2]=i4_l2; assign i4_left[3]=i4_l3;

	h264_intra4x4_pred u_i4 (
		.mode(i4_mode), .above(i4_above), .left(i4_left),
		.top_left(i4_tl), .has_above(i4_has_above), .has_left(i4_has_left),
		.used_mode(i4_used_mode), .pred(i4_pred)
	);
	assign i4_p0=i4_pred[0];   assign i4_p1=i4_pred[1];
	assign i4_p2=i4_pred[2];   assign i4_p3=i4_pred[3];
	assign i4_p4=i4_pred[4];   assign i4_p5=i4_pred[5];
	assign i4_p6=i4_pred[6];   assign i4_p7=i4_pred[7];
	assign i4_p8=i4_pred[8];   assign i4_p9=i4_pred[9];
	assign i4_p10=i4_pred[10]; assign i4_p11=i4_pred[11];
	assign i4_p12=i4_pred[12]; assign i4_p13=i4_pred[13];
	assign i4_p14=i4_pred[14]; assign i4_p15=i4_pred[15];

	wire signed [15:0] iq_coeff [0:15];
	wire signed [28:0] iq_res   [0:15];
	assign iq_coeff[0]=iq_c0;   assign iq_coeff[1]=iq_c1;
	assign iq_coeff[2]=iq_c2;   assign iq_coeff[3]=iq_c3;
	assign iq_coeff[4]=iq_c4;   assign iq_coeff[5]=iq_c5;
	assign iq_coeff[6]=iq_c6;   assign iq_coeff[7]=iq_c7;
	assign iq_coeff[8]=iq_c8;   assign iq_coeff[9]=iq_c9;
	assign iq_coeff[10]=iq_c10; assign iq_coeff[11]=iq_c11;
	assign iq_coeff[12]=iq_c12; assign iq_coeff[13]=iq_c13;
	assign iq_coeff[14]=iq_c14; assign iq_coeff[15]=iq_c15;

	h264_iq_idct_seq u_iq (
		.clk(clk), .reset(reset), .start(iq_start),
		.coeff(iq_coeff), .qp(iq_qp), .max_coeff(iq_max_coeff),
		.skip_dc(iq_skip_dc), .dc_override(iq_dc_override), .dc_value(iq_dc_value),
		.residual(iq_res), .done(iq_done)
	);
	assign iq_r0=iq_res[0];   assign iq_r1=iq_res[1];
	assign iq_r2=iq_res[2];   assign iq_r3=iq_res[3];
	assign iq_r4=iq_res[4];   assign iq_r5=iq_res[5];
	assign iq_r6=iq_res[6];   assign iq_r7=iq_res[7];
	assign iq_r8=iq_res[8];   assign iq_r9=iq_res[9];
	assign iq_r10=iq_res[10]; assign iq_r11=iq_res[11];
	assign iq_r12=iq_res[12]; assign iq_r13=iq_res[13];
	assign iq_r14=iq_res[14]; assign iq_r15=iq_res[15];

	// Parallel path: dequant4x4_flex (skip_dc/dc_override) + idct4x4
	wire signed [28:0] par_dq  [0:15];
	wire signed [28:0] par_res [0:15];

	h264_dequant4x4_flex u_par_dq (
		.coeff(iq_coeff),
		.qp(iq_qp),
		.max_coeff(iq_max_coeff),
		.skip_dc(iq_skip_dc),
		.dc_override(iq_dc_override),
		.dc_value(iq_dc_value),
		.dequant(par_dq)
	);
	h264_idct4x4 u_par_idct (
		.dequant(par_dq),
		.residual(par_res)
	);
	assign par_r0=par_res[0];   assign par_r1=par_res[1];
	assign par_r2=par_res[2];   assign par_r3=par_res[3];
	assign par_r4=par_res[4];   assign par_r5=par_res[5];
	assign par_r6=par_res[6];   assign par_r7=par_res[7];
	assign par_r8=par_res[8];   assign par_r9=par_res[9];
	assign par_r10=par_res[10]; assign par_r11=par_res[11];
	assign par_r12=par_res[12]; assign par_r13=par_res[13];
	assign par_r14=par_res[14]; assign par_r15=par_res[15];
endmodule
`default_nettype wire
