// Simulation harness: flex + plain dequant, luma/chroma DC, IDCT, optional seq.
`default_nettype none

module h264_transform_dequant_tb_top (
	input  wire         clk,
	input  wire         reset,
	input  wire         ldc_start,
	output wire         ldc_done,
	input  wire         seq_start,
	output wire         seq_done,

	input  wire [255:0] coeff16_flat,
	input  wire [63:0]  coeff4_flat,
	input  wire [5:0]   qp,
	input  wire [4:0]   max_coeff,
	input  wire         skip_dc,
	input  wire         dc_override,
	input  wire signed [28:0] dc_value,

	output wire [463:0] flex_flat,
	output wire [463:0] deq_flat,
	output wire [463:0] ldc_flat,
	output wire [115:0] cdc_flat,
	output wire [463:0] seq_flat,
	output wire [463:0] idct_flat,

	input  wire [647:0] refwin_flat,
	input  wire [2:0]   frac_x,
	input  wire [2:0]   frac_y,
	output wire [511:0] cpred_flat
);
	wire signed [15:0] coeff16 [0:15];
	wire signed [15:0] coeff4  [0:3];
	wire signed [28:0] flex    [0:15];
	wire signed [28:0] deq     [0:15];
	wire signed [28:0] ldc     [0:15];
	wire signed [28:0] cdc     [0:3];
	wire signed [28:0] seq_res [0:15];
	wire signed [28:0] idct_par [0:15];
	wire [7:0]         refwin  [0:80];
	wire [7:0]         cpred   [0:63];

`ifdef TRANSFORM_NEGATIVE_TEST
	localparam [28:0] PERTURB = 29'd1;
`else
	localparam [28:0] PERTURB = 29'd0;
`endif

	// Combo luma DC: done is immediate so TB WaitDone still works.
	assign ldc_done = 1'b1;
	// No seq module required for LevelScale audit — mirror idct of flex.
	assign seq_done = 1'b1;
	assign seq_res  = idct_par;

	genvar i;
	generate
		for (i = 0; i < 16; i = i + 1) begin : g_c16
			assign coeff16[i]            = $signed(coeff16_flat[16*i +: 16]);
			assign flex_flat[29*i +: 29] = flex[i] ^ PERTURB;
			assign deq_flat[29*i +: 29]  = deq[i] ^ PERTURB;
			assign ldc_flat[29*i +: 29]  = ldc[i] ^ PERTURB;
			assign seq_flat[29*i +: 29]  = seq_res[i] ^ PERTURB;
			assign idct_flat[29*i +: 29] = idct_par[i] ^ PERTURB;
		end
		for (i = 0; i < 4; i = i + 1) begin : g_c4
			assign coeff4[i]            = $signed(coeff4_flat[16*i +: 16]);
			assign cdc_flat[29*i +: 29] = cdc[i] ^ PERTURB;
		end
		for (i = 0; i < 81; i = i + 1) begin : g_rw
			assign refwin[i] = refwin_flat[8*i +: 8];
		end
		for (i = 0; i < 64; i = i + 1) begin : g_cp
			assign cpred_flat[8*i +: 8] = cpred[i] ^ PERTURB[7:0];
		end
	endgenerate

	h264_dequant4x4_flex u_flex (
		.coeff(coeff16), .qp(qp), .max_coeff(max_coeff),
		.skip_dc(skip_dc), .dc_override(dc_override), .dc_value(dc_value),
		.dequant(flex)
	);

	// BOTH product instances under test: flex (u_dequant) and plain (u_product_p16).
	h264_dequant4x4 u_deq (
		.coeff(coeff16), .qp(qp), .max_coeff(max_coeff), .dequant(deq)
	);

	h264_luma_dc_hadamard_inv u_ldc (
		.coeff(coeff16), .qp(qp), .dc(ldc)
	);

	h264_chroma_dc_hadamard_inv u_cdc (
		.coeff(coeff4), .qp_c(qp), .dc(cdc)
	);

	h264_idct4x4 u_idct_par (
		.dequant(flex), .residual(idct_par)
	);

	h264_chroma_epel_block_8x8 u_cep (
		.ref_win(refwin), .frac_x(frac_x), .frac_y(frac_y), .pred(cpred)
	);
endmodule

`default_nettype wire
