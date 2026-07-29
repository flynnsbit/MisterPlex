// Simulation harness for the multiplier-free transform / dequant datapath.
//
// The area work replaced every `c * LevelScale` with a shift/add
// decomposition (mul_norm) and every `x <<< qdiv` with an explicit mux
// (shl_qdiv).  Those are asserted arithmetic identities: the algorithm is
// unchanged by construction, which is exactly the class of rewrite that can
// preserve a Python golden model and still break the RTL.  This top exposes
// the combinational modules over flat vectors so the C++ bench can execute
// them and compare against the ORIGINAL multiply-and-shift expressions.
//
// Flat packing is little-endian by index: element i occupies bits
// [W*i +: W], so element 0 is the low bits.

`default_nettype none

module h264_transform_dequant_tb_top (
	input  wire [255:0] coeff16_flat,   // 16 x signed [15:0]
	input  wire [63:0]  coeff4_flat,    // 4  x signed [15:0]
	input  wire [5:0]   qp,
	input  wire [4:0]   max_coeff,
	input  wire         skip_dc,
	input  wire         dc_override,
	input  wire signed [28:0] dc_value,

	output wire [463:0] flex_flat,      // 16 x signed [28:0]
	output wire [463:0] deq_flat,       // 16 x signed [28:0]
	output wire [463:0] ldc_flat,       // 16 x signed [28:0]
	output wire [115:0] cdc_flat,       // 4  x signed [28:0]

	input  wire [647:0] refwin_flat,    // 81 x [7:0]
	input  wire [2:0]   frac_x,
	input  wire [2:0]   frac_y,
	output wire [511:0] cpred_flat      // 64 x [7:0]
);
	wire signed [15:0] coeff16 [0:15];
	wire signed [15:0] coeff4  [0:3];
	wire signed [28:0] flex    [0:15];
	wire signed [28:0] deq     [0:15];
	wire signed [28:0] ldc     [0:15];
	wire signed [28:0] cdc     [0:3];
	wire [7:0]         refwin  [0:80];
	wire [7:0]         cpred   [0:63];

	// RED proof: perturbing one LSB per output must make the bench fail.  A
	// comparison that cannot fail is not evidence, and this datapath is all
	// combinational identities, so a silently disconnected port would
	// otherwise sail through.
`ifdef TRANSFORM_NEGATIVE_TEST
	localparam [28:0] PERTURB = 29'd1;
`else
	localparam [28:0] PERTURB = 29'd0;
`endif

	genvar i;
	generate
		for (i = 0; i < 16; i = i + 1) begin : g_c16
			assign coeff16[i]                  = $signed(coeff16_flat[16*i +: 16]);
			assign flex_flat[29*i +: 29]       = flex[i] ^ PERTURB;
			assign deq_flat[29*i +: 29]        = deq[i] ^ PERTURB;
			assign ldc_flat[29*i +: 29]        = ldc[i] ^ PERTURB;
		end
		for (i = 0; i < 4; i = i + 1) begin : g_c4
			assign coeff4[i]                   = $signed(coeff4_flat[16*i +: 16]);
			assign cdc_flat[29*i +: 29]        = cdc[i] ^ PERTURB;
		end
		for (i = 0; i < 81; i = i + 1) begin : g_rw
			assign refwin[i]                   = refwin_flat[8*i +: 8];
		end
		for (i = 0; i < 64; i = i + 1) begin : g_cp
			assign cpred_flat[8*i +: 8]        = cpred[i] ^ PERTURB[7:0];
		end
	endgenerate

	h264_dequant4x4_flex u_flex (
		.coeff(coeff16),
		.qp(qp),
		.max_coeff(max_coeff),
		.skip_dc(skip_dc),
		.dc_override(dc_override),
		.dc_value(dc_value),
		.dequant(flex)
	);

	h264_dequant4x4 u_deq (
		.coeff(coeff16),
		.qp(qp),
		.max_coeff(max_coeff),
		.dequant(deq)
	);

	h264_luma_dc_hadamard_inv u_ldc (
		.coeff(coeff16),
		.qp(qp),
		.dc(ldc)
	);

	h264_chroma_dc_hadamard_inv u_cdc (
		.coeff(coeff4),
		.qp(qp),
		.dc(cdc)
	);

	h264_chroma_epel_block_8x8 u_cep (
		.ref_win(refwin),
		.frac_x(frac_x),
		.frac_y(frac_y),
		.pred(cpred)
	);
endmodule

`default_nettype wire
