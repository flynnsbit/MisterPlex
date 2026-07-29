// Intra correctness vector top — area-refactored predictors + iq_idct_seq + I16 DC Hadamard.
`default_nettype none

module intra_correctness_tb_top (
	input  wire        clk,
	input  wire        reset,

	// I16 PARALLEL_OUT=1
	input  wire        i16_start,
	input  wire [1:0]  i16_mode,
	input  wire [7:0]  i16_above_flat,
	input  wire [7:0]  i16_left_flat,
	input  wire [7:0]  i16_top_left,
	input  wire        i16_has_above,
	input  wire        i16_has_left,
	output wire        i16_valid,
	output wire [7:0]  i16_pred0,
	output wire [7:0]  i16_pred255,

	// I16 PARALLEL_OUT=0 read port
	input  wire        i16s_start,
	input  wire [1:0]  i16s_mode,
	input  wire [7:0]  i16s_above_flat,
	input  wire [7:0]  i16s_left_flat,
	input  wire [7:0]  i16s_top_left,
	input  wire        i16s_has_above,
	input  wire        i16s_has_left,
	input  wire [7:0]  i16s_rd_addr,
	output wire [7:0]  i16s_rd_data,
	output wire        i16s_valid,

	// Chroma 8x8
	input  wire        ch_start,
	input  wire [1:0]  ch_mode,
	input  wire [7:0]  ch_above_flat,
	input  wire [7:0]  ch_left_flat,
	input  wire [7:0]  ch_top_left,
	input  wire        ch_has_above,
	input  wire        ch_has_left,
	output wire        ch_valid,
	output wire [7:0]  ch_pred0,
	output wire [7:0]  ch_pred36, // br quadrant sample (4,4)

	// I4x4 combo
	input  wire [3:0]  i4_mode,
	input  wire [7:0]  i4_above0,
	input  wire [7:0]  i4_above3,
	input  wire [7:0]  i4_above4,
	input  wire [7:0]  i4_above7,
	input  wire [7:0]  i4_left0,
	input  wire        i4_has_above,
	input  wire        i4_has_left,
	output wire [7:0]  i4_pred0,
	output wire [7:0]  i4_pred3,
	output wire [7:0]  i4_pred15,
	output wire [3:0]  i4_used_mode,

	// iq_idct_seq
	input  wire        iq_start,
	input  wire signed [15:0] iq_c0,
	input  wire signed [15:0] iq_c1,
	input  wire [5:0]  iq_qp,
	input  wire        iq_skip_dc,
	input  wire        iq_dc_override,
	input  wire signed [28:0] iq_dc_value,
	output wire signed [28:0] iq_r0,
	output wire        iq_done,

	// luma DC Hadamard (sequential)
	input  wire        hm_start,
	input  wire signed [15:0] hm_c0,
	input  wire signed [15:0] hm_c1,
	input  wire [5:0]  hm_qp,
	output wire signed [28:0] hm_dc0,
	output wire signed [28:0] hm_dc1,
	output wire        hm_done
);

	wire [7:0] i16_above [0:15];
	wire [7:0] i16_left  [0:15];
	wire [7:0] i16_pred  [0:255];
	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_i16_nb
			assign i16_above[gi] = i16_above_flat + gi[7:0];
			assign i16_left[gi]  = i16_left_flat + gi[7:0];
		end
	endgenerate

	wire [7:0] i16_rd_unused;
	wire       i16_unsup_unused;
	h264_intra16x16_pred #(.PARALLEL_OUT(1)) u_i16 (
		.clk(clk), .start(i16_start), .mode(i16_mode),
		.above(i16_above), .left(i16_left), .top_left(i16_top_left),
		.has_above(i16_has_above), .has_left(i16_has_left),
		.rd_addr(8'd0), .rd_data(i16_rd_unused),
		.unsupported(i16_unsup_unused), .valid(i16_valid), .pred(i16_pred)
	);
	assign i16_pred0   = i16_pred[0];
	assign i16_pred255 = i16_pred[255];

	wire [7:0] i16s_above [0:15];
	wire [7:0] i16s_left  [0:15];
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_i16s_nb
			assign i16s_above[gi] = i16s_above_flat + gi[7:0];
			assign i16s_left[gi]  = i16s_left_flat + gi[7:0];
		end
	endgenerate

	wire [7:0] i16s_pred_unused [0:255];
	wire       i16s_unsup_unused;
	h264_intra16x16_pred #(.PARALLEL_OUT(0)) u_i16s (
		.clk(clk), .start(i16s_start), .mode(i16s_mode),
		.above(i16s_above), .left(i16s_left), .top_left(i16s_top_left),
		.has_above(i16s_has_above), .has_left(i16s_has_left),
		.rd_addr(i16s_rd_addr), .rd_data(i16s_rd_data),
		.unsupported(i16s_unsup_unused), .valid(i16s_valid), .pred(i16s_pred_unused)
	);

	wire [7:0] ch_above [0:7];
	wire [7:0] ch_left  [0:7];
	wire [7:0] ch_pred  [0:63];
	generate
		for (gi = 0; gi < 8; gi = gi + 1) begin : g_ch_nb
			assign ch_above[gi] = ch_above_flat + gi[7:0];
			assign ch_left[gi]  = ch_left_flat + gi[7:0];
		end
	endgenerate

	h264_chroma8x8_pred u_ch (
		.clk(clk), .start(ch_start), .mode(ch_mode),
		.above(ch_above), .left(ch_left), .top_left(ch_top_left),
		.has_above(ch_has_above), .has_left(ch_has_left),
		.valid(ch_valid), .pred(ch_pred)
	);
	assign ch_pred0  = ch_pred[0];
	assign ch_pred36 = ch_pred[36]; // y=4,x=4

	wire [7:0] i4_above [0:7];
	wire [7:0] i4_left  [0:3];
	wire [7:0] i4_pred  [0:15];
	assign i4_above[0] = i4_above0;
	assign i4_above[1] = i4_above0 + 8'd1;
	assign i4_above[2] = i4_above0 + 8'd2;
	assign i4_above[3] = i4_above3;
	assign i4_above[4] = i4_above4;
	assign i4_above[5] = i4_above4 + 8'd1;
	assign i4_above[6] = i4_above4 + 8'd2;
	assign i4_above[7] = i4_above7;
	assign i4_left[0] = i4_left0;
	assign i4_left[1] = i4_left0 + 8'd1;
	assign i4_left[2] = i4_left0 + 8'd2;
	assign i4_left[3] = i4_left0 + 8'd3;

	h264_intra4x4_pred u_i4 (
		.mode(i4_mode), .above(i4_above), .left(i4_left),
		.top_left(8'd40), .has_above(i4_has_above), .has_left(i4_has_left),
		.used_mode(i4_used_mode), .pred(i4_pred)
	);
	assign i4_pred0  = i4_pred[0];
	assign i4_pred3  = i4_pred[3];
	assign i4_pred15 = i4_pred[15];

	wire signed [15:0] iq_coeff [0:15];
	wire signed [28:0] iq_res [0:15];
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_iqc
			if (gi == 0) assign iq_coeff[gi] = iq_c0;
			else if (gi == 1) assign iq_coeff[gi] = iq_c1;
			else assign iq_coeff[gi] = 16'sd0;
		end
	endgenerate

	h264_iq_idct_seq u_iq (
		.clk(clk), .reset(reset), .start(iq_start),
		.coeff(iq_coeff), .qp(iq_qp), .max_coeff(5'd16),
		.skip_dc(iq_skip_dc), .dc_override(iq_dc_override), .dc_value(iq_dc_value),
		.residual(iq_res), .done(iq_done)
	);
	assign iq_r0 = iq_res[0];

	wire signed [15:0] hm_coeff [0:15];
	wire signed [28:0] hm_dc [0:15];
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_hmc
			if (gi == 0) assign hm_coeff[gi] = hm_c0;
			else if (gi == 1) assign hm_coeff[gi] = hm_c1;
			else assign hm_coeff[gi] = 16'sd0;
		end
	endgenerate

	h264_luma_dc_hadamard_inv u_hm (
		.clk(clk), .reset(reset), .start(hm_start),
		.coeff(hm_coeff), .qp(hm_qp), .dc(hm_dc), .done(hm_done)
	);
	assign hm_dc0 = hm_dc[0];
	assign hm_dc1 = hm_dc[1];
endmodule
`default_nettype wire
