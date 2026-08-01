// Inverse chroma DC 2×2 Hadamard + dequant (H.264 8.5.11 / FFmpeg
// ff_h264_chroma_dc_dequant_idct). coeff[0..3] is CAVLC scan order:
//   0→(0,0), 1→(1,0), 2→(0,1), 3→(1,1).
// dc_out[by*2+bx] is the 4×4-block DC residual (spatial domain) that
// becomes blkq[0][0] before idct4x4_add — same as host invChromaDc2x2.
//
// Combinational 2×2 — four adds + scale. Not unrolled over pixels.

`default_nettype none

module h264_chroma_dc_hadamard_inv (
	input  wire signed [15:0] coeff [0:3],
	input  wire [5:0]         qpc,           // chroma QP after Table 8-15
	output wire signed [15:0] dc_out [0:3]   // by*2+bx
);
	function automatic [4:0] mf0;
		input [2:0] qmod;
		begin
			case (qmod)
			3'd0: mf0 = 5'd10;
			3'd1: mf0 = 5'd11;
			3'd2: mf0 = 5'd13;
			3'd3: mf0 = 5'd14;
			3'd4: mf0 = 5'd16;
			default: mf0 = 5'd18;
			endcase
		end
	endfunction

	wire [2:0] qmod = qpc % 6;
	wire [3:0] qdiv = qpc / 6;
	// qmul signed so (had * qmul) stays arithmetic (unsigned qmul forces unsigned mul).
	// qmul = (mf0[qp%6]*16) << (qp/6 + 2)  — same pos0 scale as dequant4
	wire signed [31:0] qmul =
		$signed({1'b0, mf0(qmod)}) * 32'sd16 <<< (qdiv + 4'd2);

	wire signed [31:0] a0 = {{16{coeff[0][15]}}, coeff[0]};
	wire signed [31:0] b0 = {{16{coeff[1][15]}}, coeff[1]};
	wire signed [31:0] c0 = {{16{coeff[2][15]}}, coeff[2]};
	wire signed [31:0] d0 = {{16{coeff[3][15]}}, coeff[3]};

	wire signed [31:0] a = a0 + b0;
	wire signed [31:0] e = a0 - b0;
	wire signed [31:0] b = c0 - d0;
	wire signed [31:0] c = c0 + d0;

	// FFmpeg: (had * qmul) >> 7
	wire signed [31:0] r00 = (a + c) * qmul >>> 7;
	wire signed [31:0] r01 = (e + b) * qmul >>> 7;
	wire signed [31:0] r10 = (a - c) * qmul >>> 7;
	wire signed [31:0] r11 = (e - b) * qmul >>> 7;

	assign dc_out[0] = r00[15:0]; // (0,0)
	assign dc_out[1] = r01[15:0]; // (0,1) = by=0 bx=1
	assign dc_out[2] = r10[15:0]; // (1,0)
	assign dc_out[3] = r11[15:0]; // (1,1)
endmodule

`default_nettype wire
