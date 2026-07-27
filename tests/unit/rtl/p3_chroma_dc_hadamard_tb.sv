module p3_chroma_dc_hadamard_tb (
	input  wire signed [15:0] coeff [0:3],
	input  wire [5:0]         qp,
	output wire signed [17:0] dc [0:3]
);
	h264_chroma_dc_hadamard_inv uut (
		.coeff(coeff),
		.qp(qp),
		.dc(dc)
	);
endmodule
