// Phase 3.3l-2 prep: H.264 4x4 inverse-quant, IDCT residual, and pred add.
// Combinational first-block building block for the FPGA decode ladder.
// Golden fixture: tests/fixtures/p3_host_recon/mb0_luma_v1.json block 0.
//
// WIDTH: dequant/IDCT/residual are signed [28:0] (29 bits). This covers
// the full H.264 coefficient × QP space:
//   max |dequant| = 192,937,984 at coeff=±32768, QP=51, mi=2 (28 bits)
//   max |IDCT|    =  48,234,496 worst-case butterfly (26 bits)
// The 16-bit coefficient input accommodates I_16x16 DC Hadamard levels
// measured at |level|=14,573 (w-level, QP=1). Do NOT narrow below 29
// bits without re-measuring: the ±2047 spec bound for AC levels does
// not cover DC Hadamard values that flow through this same path.

module h264_dequant4x4 (
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]        qp,
	input  wire [4:0]        max_coeff,
	output wire signed [28:0] dequant [0:15]
);
	function automatic [4:0] zigzag;
		input [4:0] k;
		begin
			case (k)
			5'd0:  zigzag = 5'd0;
			5'd1:  zigzag = 5'd1;
			5'd2:  zigzag = 5'd4;
			5'd3:  zigzag = 5'd8;
			5'd4:  zigzag = 5'd5;
			5'd5:  zigzag = 5'd2;
			5'd6:  zigzag = 5'd3;
			5'd7:  zigzag = 5'd6;
			5'd8:  zigzag = 5'd9;
			5'd9:  zigzag = 5'd12;
			5'd10: zigzag = 5'd13;
			5'd11: zigzag = 5'd10;
			5'd12: zigzag = 5'd7;
			5'd13: zigzag = 5'd11;
			5'd14: zigzag = 5'd14;
			default: zigzag = 5'd15;
			endcase
		end
	endfunction

	function automatic [4:0] norm_adjust;
		input [2:0] qmod;
		input [1:0] mi;
		begin
			case ({qmod, mi})
			5'd0:  norm_adjust = 5'd10; 5'd1:  norm_adjust = 5'd13; 5'd2:  norm_adjust = 5'd16;
			5'd4:  norm_adjust = 5'd11; 5'd5:  norm_adjust = 5'd14; 5'd6:  norm_adjust = 5'd18;
			5'd8:  norm_adjust = 5'd13; 5'd9:  norm_adjust = 5'd16; 5'd10: norm_adjust = 5'd20;
			5'd12: norm_adjust = 5'd14; 5'd13: norm_adjust = 5'd18; 5'd14: norm_adjust = 5'd23;
			5'd16: norm_adjust = 5'd16; 5'd17: norm_adjust = 5'd20; 5'd18: norm_adjust = 5'd25;
			5'd20: norm_adjust = 5'd18; 5'd21: norm_adjust = 5'd23; default: norm_adjust = 5'd29;
			endcase
		end
	endfunction

	function automatic [2:0] qp_mod6;
		input [5:0] q;
		case (q)
		6'd0,6'd6,6'd12,6'd18,6'd24,6'd30,6'd36,6'd42,6'd48: qp_mod6 = 3'd0;
		6'd1,6'd7,6'd13,6'd19,6'd25,6'd31,6'd37,6'd43,6'd49: qp_mod6 = 3'd1;
		6'd2,6'd8,6'd14,6'd20,6'd26,6'd32,6'd38,6'd44,6'd50: qp_mod6 = 3'd2;
		6'd3,6'd9,6'd15,6'd21,6'd27,6'd33,6'd39,6'd45,6'd51: qp_mod6 = 3'd3;
		6'd4,6'd10,6'd16,6'd22,6'd28,6'd34,6'd40,6'd46: qp_mod6 = 3'd4;
		default: qp_mod6 = 3'd5;
		endcase
	endfunction
	function automatic [3:0] qp_div6;
		input [5:0] q;
		case (q)
		6'd0,6'd1,6'd2,6'd3,6'd4,6'd5: qp_div6 = 4'd0;
		6'd6,6'd7,6'd8,6'd9,6'd10,6'd11: qp_div6 = 4'd1;
		6'd12,6'd13,6'd14,6'd15,6'd16,6'd17: qp_div6 = 4'd2;
		6'd18,6'd19,6'd20,6'd21,6'd22,6'd23: qp_div6 = 4'd3;
		6'd24,6'd25,6'd26,6'd27,6'd28,6'd29: qp_div6 = 4'd4;
		6'd30,6'd31,6'd32,6'd33,6'd34,6'd35: qp_div6 = 4'd5;
		6'd36,6'd37,6'd38,6'd39,6'd40,6'd41: qp_div6 = 4'd6;
		6'd42,6'd43,6'd44,6'd45,6'd46,6'd47: qp_div6 = 4'd7;
		default: qp_div6 = 4'd8;
		endcase
	endfunction
	function automatic signed [31:0] mul_norm;
		input signed [31:0] c;
		input [4:0] na;
		case (na)
		5'd10: mul_norm = (c <<< 3) + (c <<< 1);
		5'd11: mul_norm = (c <<< 3) + (c <<< 1) + c;
		5'd13: mul_norm = (c <<< 3) + (c <<< 2) + c;
		5'd14: mul_norm = (c <<< 4) - (c <<< 1);
		5'd16: mul_norm = (c <<< 4);
		5'd18: mul_norm = (c <<< 4) + (c <<< 1);
		5'd20: mul_norm = (c <<< 4) + (c <<< 2);
		5'd23: mul_norm = (c <<< 4) + (c <<< 3) - c;
		5'd25: mul_norm = (c <<< 4) + (c <<< 3) + c;
		default: mul_norm = (c <<< 5) - (c <<< 1) - c;
		endcase
	endfunction
	// 0..10 shift mux — never `<<< qdiv` (DSP).
	function automatic signed [47:0] shl_amt;
		input signed [31:0] v;
		input [3:0] amt;
		case (amt)
		4'd0:  shl_amt = {{16{v[31]}}, v};
		4'd1:  shl_amt = {{15{v[31]}}, v, 1'b0};
		4'd2:  shl_amt = {{14{v[31]}}, v, 2'b0};
		4'd3:  shl_amt = {{13{v[31]}}, v, 3'b0};
		4'd4:  shl_amt = {{12{v[31]}}, v, 4'b0};
		4'd5:  shl_amt = {{11{v[31]}}, v, 5'b0};
		4'd6:  shl_amt = {{10{v[31]}}, v, 6'b0};
		4'd7:  shl_amt = {{9{v[31]}},  v, 7'b0};
		4'd8:  shl_amt = {{8{v[31]}},  v, 8'b0};
		4'd9:  shl_amt = {{7{v[31]}},  v, 9'b0};
		default: shl_amt = {{6{v[31]}}, v, 10'b0};
		endcase
	endfunction
	function automatic signed [28:0] dequant_one;
		input signed [15:0] c;
		input [5:0] q;
		input [4:0] scan;
		input       skip_dc;
		reg [4:0] z;
		reg [1:0] mi;
		reg [2:0] qmod;
		reg [3:0] qdiv;
		reg [4:0] na;
		reg signed [31:0] base;
		reg signed [31:0] base16;
		reg signed [47:0] prod;
		reg signed [47:0] rnd;
		begin
			if (skip_dc)
				z = zigzag(scan + 5'd1);
			else
				z = zigzag(scan);
			if (((z[1:0] & 2'b01) + (z[3:2] & 2'b01)) == 2'd0)
				mi = 2'd0;
			else if (((z[1:0] & 2'b01) + (z[3:2] & 2'b01)) == 2'd1)
				mi = 2'd1;
			else
				mi = 2'd2;
			qmod = qp_mod6(q);
			qdiv = qp_div6(q);
			na = norm_adjust(qmod, mi);
			// FFmpeg: ((c*na*16)<<(qdiv+2)+32)>>6 — same as flex fix in 4e0770b
			base = mul_norm({{16{c[15]}}, c}, na);
			base16 = {base[27:0], 4'b0};
			prod = shl_amt(base16, qdiv + 4'd2);
			rnd = (prod + 48'sd32) >>> 6;
			dequant_one = rnd[28:0];
		end
	endfunction

	// max_coeff==15 (chroma/I16 AC): CAVLC omits DC; coeff[k] → zigzag[k+1].
	// max_coeff==16 (luma): coeff[k] → zigzag[k]. AC-only leaves raster DC = 0.
	wire ac_only = (max_coeff == 5'd15);

	// dequant_one(..., scan, skip_dc): skip_dc uses zigzag(scan+1) for scale position.
	// AC-only: pass AC index k as scan with skip_dc=1. DC raster slot stays 0
	// until chroma Hadamard / luma I16 DC inject overwrites it post-dequant.
	wire signed [28:0] dq_full_0  = (max_coeff > 5'd0)  ? dequant_one(coeff[0],  qp, 5'd0,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_1  = (max_coeff > 5'd1)  ? dequant_one(coeff[1],  qp, 5'd1,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_2  = (max_coeff > 5'd5)  ? dequant_one(coeff[5],  qp, 5'd5,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_3  = (max_coeff > 5'd6)  ? dequant_one(coeff[6],  qp, 5'd6,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_4  = (max_coeff > 5'd2)  ? dequant_one(coeff[2],  qp, 5'd2,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_5  = (max_coeff > 5'd4)  ? dequant_one(coeff[4],  qp, 5'd4,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_6  = (max_coeff > 5'd7)  ? dequant_one(coeff[7],  qp, 5'd7,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_7  = (max_coeff > 5'd12) ? dequant_one(coeff[12], qp, 5'd12, 1'b0) : 29'sd0;
	wire signed [28:0] dq_full_8  = (max_coeff > 5'd3)  ? dequant_one(coeff[3],  qp, 5'd3,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_9  = (max_coeff > 5'd8)  ? dequant_one(coeff[8],  qp, 5'd8,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_10 = (max_coeff > 5'd11) ? dequant_one(coeff[11], qp, 5'd11, 1'b0) : 29'sd0;
	wire signed [28:0] dq_full_11 = (max_coeff > 5'd13) ? dequant_one(coeff[13], qp, 5'd13, 1'b0) : 29'sd0;
	wire signed [28:0] dq_full_12 = (max_coeff > 5'd9)  ? dequant_one(coeff[9],  qp, 5'd9,  1'b0) : 29'sd0;
	wire signed [28:0] dq_full_13 = (max_coeff > 5'd10) ? dequant_one(coeff[10], qp, 5'd10, 1'b0) : 29'sd0;
	wire signed [28:0] dq_full_14 = (max_coeff > 5'd14) ? dequant_one(coeff[14], qp, 5'd14, 1'b0) : 29'sd0;
	wire signed [28:0] dq_full_15 = (max_coeff > 5'd15) ? dequant_one(coeff[15], qp, 5'd15, 1'b0) : 29'sd0;

	// AC-only (max15): coeff[k] → zigzag[k+1] scale position via skip_dc.
	wire signed [28:0] dq_ac_1  = dequant_one(coeff[0],  qp, 5'd0,  1'b1); // → zig1
	wire signed [28:0] dq_ac_4  = dequant_one(coeff[1],  qp, 5'd1,  1'b1); // → zig2
	wire signed [28:0] dq_ac_8  = dequant_one(coeff[2],  qp, 5'd2,  1'b1); // → zig3
	wire signed [28:0] dq_ac_5  = dequant_one(coeff[3],  qp, 5'd3,  1'b1); // → zig4
	wire signed [28:0] dq_ac_2  = dequant_one(coeff[4],  qp, 5'd4,  1'b1); // → zig5
	wire signed [28:0] dq_ac_3  = dequant_one(coeff[5],  qp, 5'd5,  1'b1); // → zig6
	wire signed [28:0] dq_ac_6  = dequant_one(coeff[6],  qp, 5'd6,  1'b1); // → zig7
	wire signed [28:0] dq_ac_9  = dequant_one(coeff[7],  qp, 5'd7,  1'b1); // → zig8
	wire signed [28:0] dq_ac_12 = dequant_one(coeff[8],  qp, 5'd8,  1'b1); // → zig9
	wire signed [28:0] dq_ac_13 = dequant_one(coeff[9],  qp, 5'd9,  1'b1); // → zig10
	wire signed [28:0] dq_ac_10 = dequant_one(coeff[10], qp, 5'd10, 1'b1); // → zig11
	wire signed [28:0] dq_ac_7  = dequant_one(coeff[11], qp, 5'd11, 1'b1); // → zig12
	wire signed [28:0] dq_ac_11 = dequant_one(coeff[12], qp, 5'd12, 1'b1); // → zig13
	wire signed [28:0] dq_ac_14 = dequant_one(coeff[13], qp, 5'd13, 1'b1); // → zig14
	wire signed [28:0] dq_ac_15 = dequant_one(coeff[14], qp, 5'd14, 1'b1); // → zig15

	assign dequant[0]  = ac_only ? 29'sd0    : dq_full_0;
	assign dequant[1]  = ac_only ? dq_ac_1   : dq_full_1;
	assign dequant[2]  = ac_only ? dq_ac_2   : dq_full_2;
	assign dequant[3]  = ac_only ? dq_ac_3   : dq_full_3;
	assign dequant[4]  = ac_only ? dq_ac_4   : dq_full_4;
	assign dequant[5]  = ac_only ? dq_ac_5   : dq_full_5;
	assign dequant[6]  = ac_only ? dq_ac_6   : dq_full_6;
	assign dequant[7]  = ac_only ? dq_ac_7   : dq_full_7;
	assign dequant[8]  = ac_only ? dq_ac_8   : dq_full_8;
	assign dequant[9]  = ac_only ? dq_ac_9   : dq_full_9;
	assign dequant[10] = ac_only ? dq_ac_10  : dq_full_10;
	assign dequant[11] = ac_only ? dq_ac_11  : dq_full_11;
	assign dequant[12] = ac_only ? dq_ac_12  : dq_full_12;
	assign dequant[13] = ac_only ? dq_ac_13  : dq_full_13;
	assign dequant[14] = ac_only ? dq_ac_14  : dq_full_14;
	assign dequant[15] = ac_only ? dq_ac_15  : dq_full_15;
endmodule

// H.264 Table 8-15 chroma QP mapping (qPi = clip(QP_Y + chroma_qp_index_offset)).
module h264_chroma_qp (
	input  wire [5:0]        qp_y,
	input  wire signed [4:0] chroma_qp_index_offset,
	output wire [5:0]        qp_c
);
	wire signed [7:0] qpi_raw = $signed({1'b0, qp_y}) + $signed({{3{chroma_qp_index_offset[4]}}, chroma_qp_index_offset});
	wire [5:0] qpi = (qpi_raw < 0) ? 6'd0 : (qpi_raw > 8'sd51) ? 6'd51 : qpi_raw[5:0];
	// Non-linear map for qPi >= 30 (spec Table 8-15).
	reg [5:0] map_c;
	always @* begin
		case (qpi)
		6'd30: map_c = 6'd29;
		6'd31: map_c = 6'd30;
		6'd32: map_c = 6'd31;
		6'd33: map_c = 6'd32;
		6'd34: map_c = 6'd32;
		6'd35: map_c = 6'd33;
		6'd36: map_c = 6'd34;
		6'd37: map_c = 6'd34;
		6'd38: map_c = 6'd35;
		6'd39: map_c = 6'd35;
		6'd40: map_c = 6'd36;
		6'd41: map_c = 6'd36;
		6'd42: map_c = 6'd37;
		6'd43: map_c = 6'd37;
		6'd44: map_c = 6'd37;
		6'd45: map_c = 6'd38;
		6'd46: map_c = 6'd38;
		6'd47: map_c = 6'd38;
		6'd48: map_c = 6'd39;
		6'd49: map_c = 6'd39;
		6'd50: map_c = 6'd39;
		6'd51: map_c = 6'd39;
		default: map_c = qpi;
		endcase
	end
	assign qp_c = map_c;
endmodule

// Chroma DC 2x2 inverse Hadamard + dequant (ff_h264_chroma_dc_dequant_idct).
// coeff[] is CAVLC scan order: 0=(0,0), 1=(1,0), 2=(0,1), 3=(1,1).
// Output dc[] is raster 2x2: 0=(0,0), 1=(0,1), 2=(1,0), 3=(1,1) matching
// chroma 4x4 block order {bx + by*2} with bx horizontal.
module h264_chroma_dc_hadamard_inv (
	input  wire signed [15:0] coeff [0:3],
	input  wire [5:0]         qp_c,
	output wire signed [28:0] dc [0:3]
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

	wire signed [31:0] a0 = coeff[0];
	wire signed [31:0] b0 = coeff[1];
	wire signed [31:0] c0 = coeff[2];
	wire signed [31:0] d0 = coeff[3];
	wire signed [31:0] a = a0 + b0;
	wire signed [31:0] e = a0 - b0;
	wire signed [31:0] b = c0 - d0;
	wire signed [31:0] c = c0 + d0;
	// FFmpeg: qmul=(mf*16)<<(qdiv+2); (had*qmul)>>7 — DSP-safe shift-add
	function automatic [2:0] cqp_mod6;
		input [5:0] q;
		case (q)
		6'd0,6'd6,6'd12,6'd18,6'd24,6'd30,6'd36,6'd42,6'd48: cqp_mod6 = 3'd0;
		6'd1,6'd7,6'd13,6'd19,6'd25,6'd31,6'd37,6'd43,6'd49: cqp_mod6 = 3'd1;
		6'd2,6'd8,6'd14,6'd20,6'd26,6'd32,6'd38,6'd44,6'd50: cqp_mod6 = 3'd2;
		6'd3,6'd9,6'd15,6'd21,6'd27,6'd33,6'd39,6'd45,6'd51: cqp_mod6 = 3'd3;
		6'd4,6'd10,6'd16,6'd22,6'd28,6'd34,6'd40,6'd46: cqp_mod6 = 3'd4;
		default: cqp_mod6 = 3'd5;
		endcase
	endfunction
	function automatic [3:0] cqp_div6;
		input [5:0] q;
		case (q)
		6'd0,6'd1,6'd2,6'd3,6'd4,6'd5: cqp_div6 = 4'd0;
		6'd6,6'd7,6'd8,6'd9,6'd10,6'd11: cqp_div6 = 4'd1;
		6'd12,6'd13,6'd14,6'd15,6'd16,6'd17: cqp_div6 = 4'd2;
		6'd18,6'd19,6'd20,6'd21,6'd22,6'd23: cqp_div6 = 4'd3;
		6'd24,6'd25,6'd26,6'd27,6'd28,6'd29: cqp_div6 = 4'd4;
		6'd30,6'd31,6'd32,6'd33,6'd34,6'd35: cqp_div6 = 4'd5;
		6'd36,6'd37,6'd38,6'd39,6'd40,6'd41: cqp_div6 = 4'd6;
		6'd42,6'd43,6'd44,6'd45,6'd46,6'd47: cqp_div6 = 4'd7;
		default: cqp_div6 = 4'd8;
		endcase
	endfunction
	function automatic signed [31:0] cmul_norm;
		input signed [31:0] x;
		input [4:0] na;
		case (na)
		5'd10: cmul_norm = (x <<< 3) + (x <<< 1);
		5'd11: cmul_norm = (x <<< 3) + (x <<< 1) + x;
		5'd13: cmul_norm = (x <<< 3) + (x <<< 2) + x;
		5'd14: cmul_norm = (x <<< 4) - (x <<< 1);
		5'd16: cmul_norm = (x <<< 4);
		default: cmul_norm = (x <<< 4) + (x <<< 1);
		endcase
	endfunction
	function automatic signed [47:0] cshl;
		input signed [31:0] v;
		input [3:0] amt;
		case (amt)
		4'd0:  cshl = {{16{v[31]}}, v};
		4'd1:  cshl = {{15{v[31]}}, v, 1'b0};
		4'd2:  cshl = {{14{v[31]}}, v, 2'b0};
		4'd3:  cshl = {{13{v[31]}}, v, 3'b0};
		4'd4:  cshl = {{12{v[31]}}, v, 4'b0};
		4'd5:  cshl = {{11{v[31]}}, v, 5'b0};
		4'd6:  cshl = {{10{v[31]}}, v, 6'b0};
		4'd7:  cshl = {{9{v[31]}},  v, 7'b0};
		4'd8:  cshl = {{8{v[31]}},  v, 8'b0};
		4'd9:  cshl = {{7{v[31]}},  v, 9'b0};
		default: cshl = {{6{v[31]}}, v, 10'b0};
		endcase
	endfunction
	wire [2:0] qmod = cqp_mod6(qp_c);
	wire [3:0] qdiv = cqp_div6(qp_c);
	wire [4:0] na0 = mf0(qmod);
	wire signed [31:0] h00 = a + c;
	wire signed [31:0] h01 = e + b;
	wire signed [31:0] h10 = a - c;
	wire signed [31:0] h11 = e - b;
	wire signed [31:0] b00 = cmul_norm(h00, na0);
	wire signed [31:0] b01 = cmul_norm(h01, na0);
	wire signed [31:0] b10 = cmul_norm(h10, na0);
	wire signed [31:0] b11 = cmul_norm(h11, na0);
	wire signed [31:0] s00 = {b00[27:0], 4'b0};
	wire signed [31:0] s01 = {b01[27:0], 4'b0};
	wire signed [31:0] s10 = {b10[27:0], 4'b0};
	wire signed [31:0] s11 = {b11[27:0], 4'b0};
	wire signed [47:0] p00 = cshl(s00, qdiv + 4'd2);
	wire signed [47:0] p01 = cshl(s01, qdiv + 4'd2);
	wire signed [47:0] p10 = cshl(s10, qdiv + 4'd2);
	wire signed [47:0] p11 = cshl(s11, qdiv + 4'd2);
	wire signed [31:0] t00 = p00 >>> 7;
	wire signed [31:0] t01 = p01 >>> 7;
	wire signed [31:0] t10 = p10 >>> 7;
	wire signed [31:0] t11 = p11 >>> 7;
	// Raster for 4x4 block inject: [by][bx] with by row, bx col.
	assign dc[0] = t00[28:0]; // (0,0)
	assign dc[1] = t01[28:0]; // (0,1) — bx=1,by=0
	assign dc[2] = t10[28:0]; // (1,0) — bx=0,by=1
	assign dc[3] = t11[28:0]; // (1,1)
endmodule

module h264_idct4x4 (
	input  wire signed [28:0] dequant [0:15],
	output wire signed [28:0] residual [0:15]
);
	function automatic signed [28:0] sat29;
		input signed [31:0] v;
		begin
			if (v > 32'sd268435455) sat29 = 29'sd268435455;
			else if (v < -32'sd268435456) sat29 = ~29'sd268435455;
			else sat29 = v[28:0];
		end
	endfunction

	wire signed [31:0] b0  = dequant[0] + 29'sd32;
	wire signed [31:0] b1  = dequant[1];
	wire signed [31:0] b2  = dequant[2];
	wire signed [31:0] b3  = dequant[3];
	wire signed [31:0] b4  = dequant[4];
	wire signed [31:0] b5  = dequant[5];
	wire signed [31:0] b6  = dequant[6];
	wire signed [31:0] b7  = dequant[7];
	wire signed [31:0] b8  = dequant[8];
	wire signed [31:0] b9  = dequant[9];
	wire signed [31:0] b10 = dequant[10];
	wire signed [31:0] b11 = dequant[11];
	wire signed [31:0] b12 = dequant[12];
	wire signed [31:0] b13 = dequant[13];
	wire signed [31:0] b14 = dequant[14];
	wire signed [31:0] b15 = dequant[15];

	wire signed [31:0] r0_z0 = b0 + b2,    r0_z1 = b0 - b2,    r0_z2 = (b1 >>> 1) - b3,    r0_z3 = b1 + (b3 >>> 1);
	wire signed [31:0] r1_z0 = b4 + b6,    r1_z1 = b4 - b6,    r1_z2 = (b5 >>> 1) - b7,    r1_z3 = b5 + (b7 >>> 1);
	wire signed [31:0] r2_z0 = b8 + b10,   r2_z1 = b8 - b10,   r2_z2 = (b9 >>> 1) - b11,   r2_z3 = b9 + (b11 >>> 1);
	wire signed [31:0] r3_z0 = b12 + b14,  r3_z1 = b12 - b14,  r3_z2 = (b13 >>> 1) - b15,  r3_z3 = b13 + (b15 >>> 1);

	wire signed [31:0] t0  = r0_z0 + r0_z3, t1  = r0_z1 + r0_z2, t2  = r0_z1 - r0_z2, t3  = r0_z0 - r0_z3;
	wire signed [31:0] t4  = r1_z0 + r1_z3, t5  = r1_z1 + r1_z2, t6  = r1_z1 - r1_z2, t7  = r1_z0 - r1_z3;
	wire signed [31:0] t8  = r2_z0 + r2_z3, t9  = r2_z1 + r2_z2, t10 = r2_z1 - r2_z2, t11 = r2_z0 - r2_z3;
	wire signed [31:0] t12 = r3_z0 + r3_z3, t13 = r3_z1 + r3_z2, t14 = r3_z1 - r3_z2, t15 = r3_z0 - r3_z3;

	wire signed [31:0] c0_z0 = t0 + t8,   c0_z1 = t0 - t8,   c0_z2 = (t4 >>> 1) - t12,  c0_z3 = t4 + (t12 >>> 1);
	wire signed [31:0] c1_z0 = t1 + t9,   c1_z1 = t1 - t9,   c1_z2 = (t5 >>> 1) - t13,  c1_z3 = t5 + (t13 >>> 1);
	wire signed [31:0] c2_z0 = t2 + t10,  c2_z1 = t2 - t10,  c2_z2 = (t6 >>> 1) - t14,  c2_z3 = t6 + (t14 >>> 1);
	wire signed [31:0] c3_z0 = t3 + t11,  c3_z1 = t3 - t11,  c3_z2 = (t7 >>> 1) - t15,  c3_z3 = t7 + (t15 >>> 1);

	assign residual[0]  = sat29((c0_z0 + c0_z3) >>> 6);
	assign residual[4]  = sat29((c0_z1 + c0_z2) >>> 6);
	assign residual[8]  = sat29((c0_z1 - c0_z2) >>> 6);
	assign residual[12] = sat29((c0_z0 - c0_z3) >>> 6);
	assign residual[1]  = sat29((c1_z0 + c1_z3) >>> 6);
	assign residual[5]  = sat29((c1_z1 + c1_z2) >>> 6);
	assign residual[9]  = sat29((c1_z1 - c1_z2) >>> 6);
	assign residual[13] = sat29((c1_z0 - c1_z3) >>> 6);
	assign residual[2]  = sat29((c2_z0 + c2_z3) >>> 6);
	assign residual[6]  = sat29((c2_z1 + c2_z2) >>> 6);
	assign residual[10] = sat29((c2_z1 - c2_z2) >>> 6);
	assign residual[14] = sat29((c2_z0 - c2_z3) >>> 6);
	assign residual[3]  = sat29((c3_z0 + c3_z3) >>> 6);
	assign residual[7]  = sat29((c3_z1 + c3_z2) >>> 6);
	assign residual[11] = sat29((c3_z1 - c3_z2) >>> 6);
	assign residual[15] = sat29((c3_z0 - c3_z3) >>> 6);
endmodule

module h264_recon4x4 (
	input  wire [7:0]         pred [0:15],
	input  wire signed [28:0] residual [0:15],
	output wire [7:0]         recon [0:15]
);
	function automatic [7:0] clip8;
		input signed [29:0] v;
		begin
			if (v < 30'sd0) clip8 = 8'd0;
			else if (v > 30'sd255) clip8 = 8'd255;
			else clip8 = v[7:0];
		end
	endfunction

	assign recon[0]  = clip8($signed({1'b0, pred[0]})  + residual[0]);
	assign recon[1]  = clip8($signed({1'b0, pred[1]})  + residual[1]);
	assign recon[2]  = clip8($signed({1'b0, pred[2]})  + residual[2]);
	assign recon[3]  = clip8($signed({1'b0, pred[3]})  + residual[3]);
	assign recon[4]  = clip8($signed({1'b0, pred[4]})  + residual[4]);
	assign recon[5]  = clip8($signed({1'b0, pred[5]})  + residual[5]);
	assign recon[6]  = clip8($signed({1'b0, pred[6]})  + residual[6]);
	assign recon[7]  = clip8($signed({1'b0, pred[7]})  + residual[7]);
	assign recon[8]  = clip8($signed({1'b0, pred[8]})  + residual[8]);
	assign recon[9]  = clip8($signed({1'b0, pred[9]})  + residual[9]);
	assign recon[10] = clip8($signed({1'b0, pred[10]}) + residual[10]);
	assign recon[11] = clip8($signed({1'b0, pred[11]}) + residual[11]);
	assign recon[12] = clip8($signed({1'b0, pred[12]}) + residual[12]);
	assign recon[13] = clip8($signed({1'b0, pred[13]}) + residual[13]);
	assign recon[14] = clip8($signed({1'b0, pred[14]}) + residual[14]);
	assign recon[15] = clip8($signed({1'b0, pred[15]}) + residual[15]);
endmodule
