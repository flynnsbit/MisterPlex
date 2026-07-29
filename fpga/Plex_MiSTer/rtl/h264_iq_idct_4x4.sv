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

	// Product of a coefficient with a normAdjust table entry, built from
	// shifts and one three-input add.  H.264 picked these constants so the
	// inverse transform never needs a multiplier:
	//   10 = 8+2      11 = 8+2+1    13 = 8+4+1    14 = 16-2     16 = 16
	//   18 = 16+2     20 = 16+4     23 = 16+8-1   25 = 16+8+1   29 = 32-2-1
	function automatic signed [31:0] mul_norm(input signed [31:0] c, input [4:0] na);
		begin
			case (na)
			5'd10:   mul_norm = (c <<< 3) + (c <<< 1);
			5'd11:   mul_norm = (c <<< 3) + (c <<< 1) + c;
			5'd13:   mul_norm = (c <<< 3) + (c <<< 2) + c;
			5'd14:   mul_norm = (c <<< 4) - (c <<< 1);
			5'd16:   mul_norm = (c <<< 4);
			5'd18:   mul_norm = (c <<< 4) + (c <<< 1);
			5'd20:   mul_norm = (c <<< 4) + (c <<< 2);
			5'd23:   mul_norm = (c <<< 4) + (c <<< 3) - c;
			5'd25:   mul_norm = (c <<< 4) + (c <<< 3) + c;
			default: mul_norm = (c <<< 5) - (c <<< 1) - c;   // 29
			endcase
		end
	endfunction

	// qp is 0..51.  A general qp%6 / qp/6 becomes an lpm_divide; a 52-entry
	// ROM is a handful of LUTs and keeps the scale free of multipliers and
	// dividers.
	function automatic [2:0] qp_mod6;
		input [5:0] q;
		begin
			case (q)
			6'd0,6'd6,6'd12,6'd18,6'd24,6'd30,6'd36,6'd42,6'd48: qp_mod6 = 3'd0;
			6'd1,6'd7,6'd13,6'd19,6'd25,6'd31,6'd37,6'd43,6'd49: qp_mod6 = 3'd1;
			6'd2,6'd8,6'd14,6'd20,6'd26,6'd32,6'd38,6'd44,6'd50: qp_mod6 = 3'd2;
			6'd3,6'd9,6'd15,6'd21,6'd27,6'd33,6'd39,6'd45,6'd51: qp_mod6 = 3'd3;
			6'd4,6'd10,6'd16,6'd22,6'd28,6'd34,6'd40,6'd46:       qp_mod6 = 3'd4;
			default:                                             qp_mod6 = 3'd5;
			endcase
		end
	endfunction

	function automatic [3:0] qp_div6;
		input [5:0] q;
		begin
			case (q)
			6'd0,6'd1,6'd2,6'd3,6'd4,6'd5:       qp_div6 = 4'd0;
			6'd6,6'd7,6'd8,6'd9,6'd10,6'd11:     qp_div6 = 4'd1;
			6'd12,6'd13,6'd14,6'd15,6'd16,6'd17: qp_div6 = 4'd2;
			6'd18,6'd19,6'd20,6'd21,6'd22,6'd23: qp_div6 = 4'd3;
			6'd24,6'd25,6'd26,6'd27,6'd28,6'd29: qp_div6 = 4'd4;
			6'd30,6'd31,6'd32,6'd33,6'd34,6'd35: qp_div6 = 4'd5;
			6'd36,6'd37,6'd38,6'd39,6'd40,6'd41: qp_div6 = 4'd6;
			6'd42,6'd43,6'd44,6'd45,6'd46,6'd47: qp_div6 = 4'd7;
			default:                             qp_div6 = 4'd8; // 48..51
			endcase
		end
	endfunction

	// Explicit mux, not `v <<< qdiv`.  Quartus's automatic DSP replacement
	// turns a variable-distance barrel shifter into a multiply by 1<<qdiv and
	// packs it into a DSP block.  qP <= 51 bounds qdiv to 0..8.
	function automatic signed [39:0] shl_qdiv(input signed [39:0] v, input [3:0] q);
		begin
			case (q)
			4'd0:    shl_qdiv = v;
			4'd1:    shl_qdiv = {v[38:0], 1'b0};
			4'd2:    shl_qdiv = {v[37:0], 2'b0};
			4'd3:    shl_qdiv = {v[36:0], 3'b0};
			4'd4:    shl_qdiv = {v[35:0], 4'b0};
			4'd5:    shl_qdiv = {v[34:0], 5'b0};
			4'd6:    shl_qdiv = {v[33:0], 6'b0};
			4'd7:    shl_qdiv = {v[32:0], 7'b0};
			default: shl_qdiv = {v[31:0], 8'b0};
			endcase
		end
	endfunction

	function automatic [4:0] scan_of_raster;
		input [3:0] r;
		begin
			case (r)
			4'd0:  scan_of_raster = 5'd0;  4'd1:  scan_of_raster = 5'd1;
			4'd2:  scan_of_raster = 5'd5;  4'd3:  scan_of_raster = 5'd6;
			4'd4:  scan_of_raster = 5'd2;  4'd5:  scan_of_raster = 5'd4;
			4'd6:  scan_of_raster = 5'd7;  4'd7:  scan_of_raster = 5'd12;
			4'd8:  scan_of_raster = 5'd3;  4'd9:  scan_of_raster = 5'd8;
			4'd10: scan_of_raster = 5'd11; 4'd11: scan_of_raster = 5'd13;
			4'd12: scan_of_raster = 5'd9;  4'd13: scan_of_raster = 5'd10;
			4'd14: scan_of_raster = 5'd14; default: scan_of_raster = 5'd15;
			endcase
		end
	endfunction

	// Shared once: dequant_one() with q%6/q/6 was replicated 16x and each
	// copy pulled its own divider.
	wire [2:0] qmod = qp_mod6(qp);
	wire [3:0] qdiv = qp_div6(qp);

	genvar r;
	generate
		for (r = 0; r < 16; r = r + 1) begin : g_dq
			localparam int RI = r;
			// mi from odd raster coordinates (col LSB + row LSB)
			localparam [1:0] MI = ((RI % 2) != 0 ? 2'd1 : 2'd0) +
			                      (((RI / 4) % 2) != 0 ? 2'd1 : 2'd0);
			wire [4:0] sk = scan_of_raster(RI[3:0]);
			wire signed [15:0] c = (max_coeff > sk) ? coeff[sk[3:0]] : 16'sd0;
			// 8.5.12.1 flat weight: (c * normAdjust) << (qP/6)
			wire signed [31:0] base = mul_norm(32'($signed(c)), norm_adjust(qmod, MI));
			wire signed [39:0] prod = shl_qdiv($signed({{8{base[31]}}, base}), qdiv);
			assign dequant[r] = prod[28:0];
		end
	endgenerate
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
