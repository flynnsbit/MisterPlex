// Legacy module name retained for source compatibility. Coefficients are
// signed syntax values, not pixels: no saturation is legal before transform.

`default_nettype none

module h264_coeff_sat9 (
	input  wire signed [15:0] cavlc_coeff [0:15],
	output wire signed [15:0] residual_coeff [0:15]
);

	genvar i;
	generate
		for (i = 0; i < 16; i = i + 1) begin : gen_sat
			assign residual_coeff[i] = cavlc_coeff[i];
		end
	endgenerate
endmodule

`default_nettype wire
