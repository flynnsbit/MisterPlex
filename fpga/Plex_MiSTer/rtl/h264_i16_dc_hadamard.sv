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

	function automatic [2:0] qp_mod6;
		input [5:0] q;
		begin
			case (q)
			6'd0, 6'd6, 6'd12, 6'd18, 6'd24, 6'd30, 6'd36, 6'd42, 6'd48: qp_mod6 = 3'd0;
			6'd1, 6'd7, 6'd13, 6'd19, 6'd25, 6'd31, 6'd37, 6'd43, 6'd49: qp_mod6 = 3'd1;
			6'd2, 6'd8, 6'd14, 6'd20, 6'd26, 6'd32, 6'd38, 6'd44, 6'd50: qp_mod6 = 3'd2;
			6'd3, 6'd9, 6'd15, 6'd21, 6'd27, 6'd33, 6'd39, 6'd45, 6'd51: qp_mod6 = 3'd3;
			6'd4, 6'd10, 6'd16, 6'd22, 6'd28, 6'd34, 6'd40, 6'd46:       qp_mod6 = 3'd4;
			default:                                                     qp_mod6 = 3'd5;
			endcase
		end
	endfunction

	function automatic [3:0] qp_div6;
		input [5:0] q;
		begin
			case (q)
			6'd0,  6'd1,  6'd2,  6'd3,  6'd4,  6'd5:  qp_div6 = 4'd0;
			6'd6,  6'd7,  6'd8,  6'd9,  6'd10, 6'd11: qp_div6 = 4'd1;
			6'd12, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17: qp_div6 = 4'd2;
			6'd18, 6'd19, 6'd20, 6'd21, 6'd22, 6'd23: qp_div6 = 4'd3;
			6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29: qp_div6 = 4'd4;
			6'd30, 6'd31, 6'd32, 6'd33, 6'd34, 6'd35: qp_div6 = 4'd5;
			6'd36, 6'd37, 6'd38, 6'd39, 6'd40, 6'd41: qp_div6 = 4'd6;
			6'd42, 6'd43, 6'd44, 6'd45, 6'd46, 6'd47: qp_div6 = 4'd7;
			default:                                   qp_div6 = 4'd8;
			endcase
		end
	endfunction

	// Host: qmul=(mf0*16)<<(qdiv+2); dc=((z*qmul)+128)>>8
	// Shift-add: ((z*mf0)<<(qdiv+6)+128)>>8 — 0 DSP (was 16 parallel mults).
	function automatic signed [31:0] scale_dc;
		input signed [31:0] z;
		input [2:0] qmod;
		input [3:0] qdiv;
		reg signed [63:0] x;
		reg signed [63:0] prod;
		reg [4:0] n;
		begin
			n = mf0(qmod);
			x = {{32{z[31]}}, z};
			case (n)
			5'd10: prod = (x <<< 3) + (x <<< 1);
			5'd11: prod = (x <<< 3) + (x <<< 1) + x;
			5'd13: prod = (x <<< 3) + (x <<< 2) + x;
			5'd14: prod = (x <<< 3) + (x <<< 2) + (x <<< 1);
			5'd16: prod = (x <<< 4);
			default: prod = (x <<< 4) + (x <<< 1); // 18
			endcase
			scale_dc = ((prod <<< (qdiv + 4'd6)) + 64'sd128) >>> 8;
		end
	endfunction

	wire [2:0] qmod = qp_mod6(qp);
	wire [3:0] qdiv = qp_div6(qp);

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
		// second stage + scale; dc_out row-major by*4+bx
		for (i = 0; i < 4; i = i + 1) begin
			z0 = temp[4*0+i] + temp[4*2+i];
			z1 = temp[4*0+i] - temp[4*2+i];
			z2 = temp[4*1+i] - temp[4*3+i];
			z3 = temp[4*1+i] + temp[4*3+i];
			dc_raw[i*4+0] = scale_dc(z0 + z3, qmod, qdiv);
			dc_raw[i*4+1] = scale_dc(z1 + z2, qmod, qdiv);
			dc_raw[i*4+2] = scale_dc(z1 - z2, qmod, qdiv);
			dc_raw[i*4+3] = scale_dc(z0 - z3, qmod, qdiv);
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
