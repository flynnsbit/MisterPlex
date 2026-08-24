// H.264 Expert contract: CAVLC s16 → dequant s9.
// h264_cavlc_residual_block.coeff[0:15] is signed [15:0] (scan order).
// h264_dequant4x4.coeff[0:15] is signed [8:0].
// Saturate, do not wrap. Do not use sat8 here (sat8 is telemetry only).
//
// Range into dequant: -256 .. +255
//   v >  255 →  255
//   v < -256 → -256
//   else       v[8:0]
//
// Telemetry (NOT this module):
//   residual_dc   = sat8(coeff[0])           // -128 .. +127
//   residual_csum = XOR_i sat8(coeff[i])     // locked Baseline = 0x14
// Locked first-block residual_coeff is a no-op through sat9.
// Widen dequant to s16 later if a real Plex stream exceeds ±255.

`default_nettype none

module h264_coeff_sat9 (
	input  wire signed [15:0] cavlc_coeff [0:15],
	output wire signed [8:0]  residual_coeff [0:15]
);
	function automatic signed [8:0] sat9;
		input signed [15:0] v;
		begin
			if (v > 16'sd255)
				sat9 = 9'sd255;
			else if (v < -16'sd256)
				sat9 = -9'sd256;
			else
				sat9 = v[8:0];
		end
	endfunction

	genvar i;
	generate
		for (i = 0; i < 16; i = i + 1) begin : gen_sat
			assign residual_coeff[i] = sat9(cavlc_coeff[i]);
		end
	endgenerate
endmodule

`default_nettype wire
