// Chroma DC 2x2: inv-quant + Hadamard (ITU 8.5.11 / 4:2:0).
// Bit-exact to host detail_r::invChromaDc2x2 / FFmpeg ff_h264_chroma_dc_dequant_idct.
// NOT the AC 4x4 path in h264_iq_idct_4x4.sv. NOT luma I16 DC.
//
// coeff_scan[0:3] = CAVLC chroma-DC scan (max=4) = FFmpeg ff_h264_chroma_dc_scan:
//   0 → (0,0), 1 → (1,0), 2 → (0,1), 3 → (1,1).
// qp MUST be qPc (h264_chroma_qp), not QPy.
// dc_out[y*2+x] = host dc[y][x] int16. Do not sat9 dc_out.
// Consumer: AC 4x4 DC slot gets this value before chroma IQ/IDCT.
//
// Proof (qp=qPc=25, scan={1,0,0,0}):
//   qmul = (11*16) << (4+2) = 11264
//   dc_out = {88, 88, 88, 88}
//
// Do not instantiate from Plex.sv / stream_path.

`default_nettype none

module h264_chroma_dc_hadamard (
	input  wire signed [15:0] coeff_scan [0:3],
	input  wire [5:0]         qp,
	output reg  signed [15:0] dc_out [0:3]
);
	function automatic integer mf0_of;
		input [5:0] q;
		begin
			case (q % 6)
			0: mf0_of = 10;
			1: mf0_of = 11;
			2: mf0_of = 13;
			3: mf0_of = 14;
			4: mf0_of = 16;
			default: mf0_of = 18;
			endcase
		end
	endfunction

	integer a0, b0, c0, d0;
	integer a, e, b, c;
	integer qmul;

	always @* begin
		a0 = coeff_scan[0];
		b0 = coeff_scan[1];
		c0 = coeff_scan[2];
		d0 = coeff_scan[3];
		a = a0 + b0;
		e = a0 - b0;
		b = c0 - d0;
		c = c0 + d0;
		qmul = (mf0_of(qp) * 16) << ((qp / 6) + 2);
		dc_out[0] = ((a + c) * qmul) >>> 7; // (0,0)
		dc_out[1] = ((e + b) * qmul) >>> 7; // (0,1) host dc[0][1]
		dc_out[2] = ((a - c) * qmul) >>> 7; // (1,0) host dc[1][0]
		dc_out[3] = ((e - b) * qmul) >>> 7; // (1,1)
	end
endmodule

`default_nettype wire
