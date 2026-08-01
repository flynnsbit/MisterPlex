// I_16x16 luma DC: inverse Hadamard + dequant (FFmpeg ff_h264_luma_dc_dequant_idct layout).
// coeff[] is CAVLC zigzag order (max_coeff=16). dc_out[by][bx] is the per-4x4 DC
// residual in the domain where pixel = Clip1(pred + ((dc + 32) >> 6)).
//
// Ported from host misterplex::cavlc::invQuantHadamardDc4x4 — keep in lockstep.

`default_nettype none

module h264_i16_dc_hadamard (
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	output wire signed [15:0] dc_out [0:15] // row-major 4x4: idx = by*4+bx
);
	// zigzag scan positions
	function automatic [3:0] zz;
		input [3:0] i;
		begin
			case (i)
			4'd0: zz = 4'd0; 4'd1: zz = 4'd1; 4'd2: zz = 4'd4; 4'd3: zz = 4'd8;
			4'd4: zz = 4'd5; 4'd5: zz = 4'd2; 4'd6: zz = 4'd3; 4'd7: zz = 4'd6;
			4'd8: zz = 4'd9; 4'd9: zz = 4'd12; 4'd10: zz = 4'd13; 4'd11: zz = 4'd10;
			4'd12: zz = 4'd7; 4'd13: zz = 4'd11; 4'd14: zz = 4'd14; default: zz = 4'd15;
			endcase
		end
	endfunction

	// FFmpeg TRANSPOSE(x) = (x>>2) | ((x<<2)&0xF)
	function automatic [3:0] transpose4;
		input [3:0] z;
		begin
			transpose4 = {z[1:0], z[3:2]}; // (z>>2)|((z<<2)&0xF) for 4-bit
		end
	endfunction

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

	// qmul = (mf0[qp%6] * 16) << (qp/6 + 2)
	wire [2:0] qmod = qp % 6;
	wire [3:0] qdiv = qp / 6;
	wire [31:0] qmul = ({27'd0, mf0(qmod)} * 32'd16) << (qdiv + 4'd2);

	reg signed [31:0] input_cm [0:15];
	reg signed [31:0] temp [0:15];
	reg signed [31:0] dc_raw [0:15];
	integer i, t, z0, z1, z2, z3;
	integer zi, tr;

	always @(*) begin
		for (i = 0; i < 16; i = i + 1)
			input_cm[i] = 32'sd0;
		for (i = 0; i < 16; i = i + 1) begin
			zi = zz(i[3:0]);
			tr = transpose4(zi[3:0]);
			input_cm[tr] = coeff[i];
		end
		// first stage (rows)
		for (i = 0; i < 4; i = i + 1) begin
			z0 = input_cm[4*i+0] + input_cm[4*i+1];
			z1 = input_cm[4*i+0] - input_cm[4*i+1];
			z2 = input_cm[4*i+2] - input_cm[4*i+3];
			z3 = input_cm[4*i+2] + input_cm[4*i+3];
			temp[4*i+0] = z0 + z3;
			temp[4*i+1] = z0 - z3;
			temp[4*i+2] = z1 - z2;
			temp[4*i+3] = z1 + z2;
		end
		// second stage + qmul; dc_out[i][0..3] with i = row of 4x4s
		// Host: dcOut[i][0] = ((z0+z3)*qmul+128)>>8  where i is column index in second loop
		// Host loop: for i in 0..3: uses temp[4*row+i] — i is column of temp.
		// dcOut[i][lx] with i as first index = row of 4x4 blocks? Host recon uses dc[ly][lx]
		// and second loop sets dcOut[i][0..3] with i from 0..3 = first index.
		for (i = 0; i < 4; i = i + 1) begin
			z0 = temp[4*0+i] + temp[4*2+i];
			z1 = temp[4*0+i] - temp[4*2+i];
			z2 = temp[4*1+i] - temp[4*3+i];
			z3 = temp[4*1+i] + temp[4*3+i];
			// row-major out: by=i, bx=0..3 → idx = i*4+bx
			dc_raw[i*4+0] = ((z0 + z3) * qmul + 32'sd128) >>> 8;
			dc_raw[i*4+1] = ((z1 + z2) * qmul + 32'sd128) >>> 8;
			dc_raw[i*4+2] = ((z1 - z2) * qmul + 32'sd128) >>> 8;
			dc_raw[i*4+3] = ((z0 - z3) * qmul + 32'sd128) >>> 8;
		end
	end

	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : gen_dc
			assign dc_out[gi] = dc_raw[gi][15:0];
		end
	endgenerate
endmodule

`default_nettype wire
