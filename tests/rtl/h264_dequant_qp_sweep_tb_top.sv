// Testbench wrapper for exhaustive QP 0–51 dequant sweep.
// Instantiates ONLY h264_dequant4x4 from the product RTL — no forks.
// Uses `ifdef to handle both 18-bit (pre-fix) and 22-bit (post-fix) output.
`default_nettype none

module h264_dequant_qp_sweep_tb (
	input  wire signed [8:0]  coeff    [0:15],
	input  wire        [4:0]  max_coeff,
	input  wire        [5:0]  qp,
	output wire signed [21:0] dequant  [0:15]
);

	h264_dequant4x4 u_dequant (
		.coeff(coeff),
		.qp(qp),
		.max_coeff(max_coeff),
		.dequant(dequant)
	);

endmodule

`default_nettype wire
