// Minimal TB: chroma DC 2x2 Hadamard+dequant vs host invChromaDc2x2 vectors.
`default_nettype none
module p3_chroma_dc_hadamard_tb (
	input  wire signed [15:0] c0,
	input  wire signed [15:0] c1,
	input  wire signed [15:0] c2,
	input  wire signed [15:0] c3,
	input  wire [5:0]         qpc,
	output wire signed [15:0] d0,
	output wire signed [15:0] d1,
	output wire signed [15:0] d2,
	output wire signed [15:0] d3
);
	wire signed [15:0] coeff [0:3];
	wire signed [15:0] dc_out [0:3];
	assign coeff[0] = c0;
	assign coeff[1] = c1;
	assign coeff[2] = c2;
	assign coeff[3] = c3;
	h264_chroma_dc_hadamard_inv u_dut (
		.coeff(coeff),
		.qpc(qpc),
		.dc_out(dc_out)
	);
	assign d0 = dc_out[0];
	assign d1 = dc_out[1];
	assign d2 = dc_out[2];
	assign d3 = dc_out[3];
endmodule
`default_nettype wire
