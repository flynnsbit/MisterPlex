// H.264 Baseline DC transform, chroma QP mapping and flexible 4x4 dequant.
//
// These are the pieces of the inverse transform chain that h264_iq_idct_4x4.sv
// does not cover:
//
//   h264_chroma_qp              - Table 8-15 QPy -> QPc mapping (8.5.8)
//   h264_luma_dc_hadamard_inv   - Intra_16x16 luma DC 4x4 Hadamard + scale (8.5.10)
//   h264_chroma_dc_hadamard_inv - 4:2:0 chroma DC 2x2 Hadamard + scale (8.5.11)
//   h264_dequant4x4_flex        - 8.5.12.1 scaling with inverse zig-zag, optional
//                                 AC-only (DC skipped) input and DC substitution
//
// Scale domain contract: every "d" value produced here is in the same domain as
// h264_dequant4x4, i.e. d = c * normAdjust(qP%6,i,j) << (qP/6), so it feeds
// straight into h264_idct4x4 which finishes with (f + 32) >> 6.
//
// OWNER: w-residual (inverse transform chain)

// 7.4.5: QP_Y = (QP_Y_PREV + mb_qp_delta + 52) % 52  (two-sided wrap)
module h264_qp_y_add_delta (
	input  wire [5:0]         prev_qp,
	input  wire signed [7:0]  mb_qp_delta,
	output wire [5:0]         qp_y
);
	wire signed [9:0] sum0 = $signed({4'b0, prev_qp}) + mb_qp_delta;
	wire signed [9:0] adj0 = (sum0 < 10'sd0)  ? (sum0 + 10'sd52) :
	                         (sum0 > 10'sd51) ? (sum0 - 10'sd52) : sum0;
	wire signed [9:0] adj1 = (adj0 < 10'sd0)  ? (adj0 + 10'sd52) :
	                         (adj0 > 10'sd51) ? (adj0 - 10'sd52) : adj0;
	assign qp_y = adj1[5:0];
endmodule

module h264_chroma_qp (
	input  wire [5:0]        qp_y,
	input  wire signed [4:0] chroma_qp_index_offset,
	output wire [5:0]        qp_c
);
	wire signed [7:0] qpi_raw = $signed({2'b00, qp_y}) +
	                            $signed({{3{chroma_qp_index_offset[4]}}, chroma_qp_index_offset});
	wire signed [7:0] qpi_clip = (qpi_raw < 8'sd0)  ? 8'sd0  :
	                             (qpi_raw > 8'sd51) ? 8'sd51 : qpi_raw;
	wire [5:0] qpi = qpi_clip[5:0];

	function automatic [5:0] qpc_table;
		input [5:0] q;
		begin
			case (q)
			6'd30: qpc_table = 6'd29;
			6'd31: qpc_table = 6'd30;
			6'd32: qpc_table = 6'd31;
			6'd33: qpc_table = 6'd32;
			6'd34: qpc_table = 6'd32;
			6'd35: qpc_table = 6'd33;
			6'd36: qpc_table = 6'd34;
			6'd37: qpc_table = 6'd34;
			6'd38: qpc_table = 6'd35;
			6'd39: qpc_table = 6'd35;
			6'd40: qpc_table = 6'd36;
			6'd41: qpc_table = 6'd36;
			6'd42: qpc_table = 6'd37;
			6'd43: qpc_table = 6'd37;
			6'd44: qpc_table = 6'd37;
			6'd45: qpc_table = 6'd38;
			6'd46: qpc_table = 6'd38;
			6'd47: qpc_table = 6'd38;
			6'd48: qpc_table = 6'd39;
			6'd49: qpc_table = 6'd39;
			6'd50: qpc_table = 6'd39;
			6'd51: qpc_table = 6'd39;
			default: qpc_table = q;
			endcase
		end
	endfunction

	assign qp_c = (qpi < 6'd30) ? qpi : qpc_table(qpi);
endmodule

module h264_luma_dc_hadamard_inv (
	// Intra16x16DCLevel in CAVLC scan order (zig-zag over the 4x4 DC array).
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	output wire signed [28:0] dc [0:15]     // raster order; d[0][0] of each 4x4
);
	function automatic [4:0] norm_adjust0;
		input [2:0] qmod;
		begin
			case (qmod)
			3'd0: norm_adjust0 = 5'd10;
			3'd1: norm_adjust0 = 5'd11;
			3'd2: norm_adjust0 = 5'd13;
			3'd3: norm_adjust0 = 5'd14;
			3'd4: norm_adjust0 = 5'd16;
			default: norm_adjust0 = 5'd18;
			endcase
		end
	endfunction

	function automatic [3:0] scan_of_raster;
		input [3:0] r;
		begin
			case (r)
			4'd0:  scan_of_raster = 4'd0;
			4'd1:  scan_of_raster = 4'd1;
			4'd2:  scan_of_raster = 4'd5;
			4'd3:  scan_of_raster = 4'd6;
			4'd4:  scan_of_raster = 4'd2;
			4'd5:  scan_of_raster = 4'd4;
			4'd6:  scan_of_raster = 4'd7;
			4'd7:  scan_of_raster = 4'd12;
			4'd8:  scan_of_raster = 4'd3;
			4'd9:  scan_of_raster = 4'd8;
			4'd10: scan_of_raster = 4'd11;
			4'd11: scan_of_raster = 4'd13;
			4'd12: scan_of_raster = 4'd9;
			4'd13: scan_of_raster = 4'd10;
			4'd14: scan_of_raster = 4'd14;
			default: scan_of_raster = 4'd15;
			endcase
		end
	endfunction

	function automatic signed [28:0] sat29;
		input signed [47:0] v;
		begin
			if (v > 48'sd268435455) sat29 = 29'sd268435455;
			else if (v < -48'sd268435456) sat29 = ~29'sd268435455;
			else sat29 = v[28:0];
		end
	endfunction

	// Inverse zig-zag: c[raster] = coeff[scan_of_raster(raster)]
	wire signed [20:0] c [0:15];
	genvar zi;
	generate
		for (zi = 0; zi < 16; zi = zi + 1) begin : g_izz
			localparam int ZI = zi;
			assign c[zi] = $signed(coeff[scan_of_raster(ZI[3:0])]);
		end
	endgenerate

	// Row transform: g = c * H, H = [1 1 1 1; 1 1 -1 -1; 1 -1 -1 1; 1 -1 1 -1]
	wire signed [22:0] g0  = c[0]  + c[1]  + c[2]  + c[3];
	wire signed [22:0] g1  = c[0]  + c[1]  - c[2]  - c[3];
	wire signed [22:0] g2  = c[0]  - c[1]  - c[2]  + c[3];
	wire signed [22:0] g3  = c[0]  - c[1]  + c[2]  - c[3];
	wire signed [22:0] g4  = c[4]  + c[5]  + c[6]  + c[7];
	wire signed [22:0] g5  = c[4]  + c[5]  - c[6]  - c[7];
	wire signed [22:0] g6  = c[4]  - c[5]  - c[6]  + c[7];
	wire signed [22:0] g7  = c[4]  - c[5]  + c[6]  - c[7];
	wire signed [22:0] g8  = c[8]  + c[9]  + c[10] + c[11];
	wire signed [22:0] g9  = c[8]  + c[9]  - c[10] - c[11];
	wire signed [22:0] g10 = c[8]  - c[9]  - c[10] + c[11];
	wire signed [22:0] g11 = c[8]  - c[9]  + c[10] - c[11];
	wire signed [22:0] g12 = c[12] + c[13] + c[14] + c[15];
	wire signed [22:0] g13 = c[12] + c[13] - c[14] - c[15];
	wire signed [22:0] g14 = c[12] - c[13] - c[14] + c[15];
	wire signed [22:0] g15 = c[12] - c[13] + c[14] - c[15];

	// Column transform: f = H * g
	wire signed [24:0] f [0:15];
	assign f[0]  = g0  + g4  + g8  + g12;
	assign f[1]  = g1  + g5  + g9  + g13;
	assign f[2]  = g2  + g6  + g10 + g14;
	assign f[3]  = g3  + g7  + g11 + g15;
	assign f[4]  = g0  + g4  - g8  - g12;
	assign f[5]  = g1  + g5  - g9  - g13;
	assign f[6]  = g2  + g6  - g10 - g14;
	assign f[7]  = g3  + g7  - g11 - g15;
	assign f[8]  = g0  - g4  - g8  + g12;
	assign f[9]  = g1  - g5  - g9  + g13;
	assign f[10] = g2  - g6  - g10 + g14;
	assign f[11] = g3  - g7  - g11 + g15;
	assign f[12] = g0  - g4  + g8  - g12;
	assign f[13] = g1  - g5  + g9  - g13;
	assign f[14] = g2  - g6  + g10 - g14;
	assign f[15] = g3  - g7  + g11 - g15;

	// LevelScale(qP%6,0,0) = 16 * normAdjust(qP%6,0).  The x16 is folded into
	// the rounding shift below so the datapath never has to carry it.
	wire [5:0] qmod6 = qp % 6;
	wire [5:0] qdiv6 = qp / 6;
	wire [2:0] qmod = qmod6[2:0];
	wire [3:0] qdiv = qdiv6[3:0];
	wire [4:0] na = norm_adjust0(qmod);

	// dcY = (f * LevelScale << (qP/6) + 32) >> 6  — identical to both 8.5.10
	// branches.  AREA: normAdjust is at most 5 bits, so the product is five
	// shifted copies of f rather than a multiplier; sixteen of these were
	// consuming sixteen DSP blocks on a device that is over its DSP budget.
	//   ((f*na*16 << qdiv) + 32) >> 6  ==  ((f*na << qdiv) + 2) >> 2
	genvar di;
	generate
		for (di = 0; di < 16; di = di + 1) begin : g_dc
			wire signed [29:0] fw = {{5{f[di][24]}}, f[di]};
			wire signed [29:0] mul = (na[0] ? fw          : 30'sd0)
			                       + (na[1] ? (fw <<< 1)  : 30'sd0)
			                       + (na[2] ? (fw <<< 2)  : 30'sd0)
			                       + (na[3] ? (fw <<< 3)  : 30'sd0)
			                       + (na[4] ? (fw <<< 4)  : 30'sd0);
			wire signed [43:0] prod = $signed({{14{mul[29]}}, mul}) <<< qdiv;
			wire signed [43:0] rnd  = (prod + 44'sd2) >>> 2;
			assign dc[di] = sat29({{4{rnd[43]}}, rnd});
		end
	endgenerate
endmodule

module h264_chroma_dc_hadamard_inv (
	input  wire signed [15:0] coeff [0:3],  // raster c[0][0], c[0][1], c[1][0], c[1][1]
	input  wire [5:0]         qp,           // QPc
	output wire signed [28:0] dc [0:3]
);
	function automatic [4:0] norm_adjust0;
		input [2:0] qmod;
		begin
			case (qmod)
			3'd0: norm_adjust0 = 5'd10;
			3'd1: norm_adjust0 = 5'd11;
			3'd2: norm_adjust0 = 5'd13;
			3'd3: norm_adjust0 = 5'd14;
			3'd4: norm_adjust0 = 5'd16;
			default: norm_adjust0 = 5'd18;
			endcase
		end
	endfunction

	function automatic signed [28:0] sat29;
		input signed [47:0] v;
		begin
			if (v > 48'sd268435455) sat29 = 29'sd268435455;
			else if (v < -48'sd268435456) sat29 = ~29'sd268435455;
			else sat29 = v[28:0];
		end
	endfunction

	wire signed [17:0] c0 = $signed(coeff[0]);
	wire signed [17:0] c1 = $signed(coeff[1]);
	wire signed [17:0] c2 = $signed(coeff[2]);
	wire signed [17:0] c3 = $signed(coeff[3]);

	// f = [1 1; 1 -1] * c * [1 1; 1 -1]
	wire signed [19:0] f [0:3];
	assign f[0] = c0 + c1 + c2 + c3;
	assign f[1] = c0 - c1 + c2 - c3;
	assign f[2] = c0 + c1 - c2 - c3;
	assign f[3] = c0 - c1 - c2 + c3;

	wire [5:0] qmod6 = qp % 6;
	wire [5:0] qdiv6 = qp / 6;
	wire [2:0] qmod = qmod6[2:0];
	wire [3:0] qdiv = qdiv6[3:0];
	wire [4:0] na = norm_adjust0(qmod);

	// dcC = ((f * LevelScale(qP%6,0,0)) << (qP/6)) >> 5   (8.5.11.2)
	// Shift/add product, x16 folded into the shift:  (16X) >>> 5 == X >>> 1.
	genvar di;
	generate
		for (di = 0; di < 4; di = di + 1) begin : g_cdc
			wire signed [24:0] fw = {{5{f[di][19]}}, f[di]};
			wire signed [24:0] mul = (na[0] ? fw          : 25'sd0)
			                       + (na[1] ? (fw <<< 1)  : 25'sd0)
			                       + (na[2] ? (fw <<< 2)  : 25'sd0)
			                       + (na[3] ? (fw <<< 3)  : 25'sd0)
			                       + (na[4] ? (fw <<< 4)  : 25'sd0);
			wire signed [39:0] prod = $signed({{15{mul[24]}}, mul}) <<< qdiv;
			wire signed [39:0] rnd  = prod >>> 1;
			assign dc[di] = sat29({{8{rnd[39]}}, rnd});
		end
	endgenerate
endmodule

// 8.5.12.1 scaling with inverse zig-zag placement.
//   skip_dc     : coeff[0..14] carry scan positions 1..15 (AC-only block)
//   dc_override : raster position 0 is taken from dc_value instead of coeff
module h264_dequant4x4_flex (
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	input  wire [4:0]         max_coeff,
	input  wire               skip_dc,
	input  wire               dc_override,
	input  wire signed [28:0] dc_value,
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

	function automatic [3:0] scan_of_raster;
		input [3:0] r;
		begin
			case (r)
			4'd0:  scan_of_raster = 4'd0;
			4'd1:  scan_of_raster = 4'd1;
			4'd2:  scan_of_raster = 4'd5;
			4'd3:  scan_of_raster = 4'd6;
			4'd4:  scan_of_raster = 4'd2;
			4'd5:  scan_of_raster = 4'd4;
			4'd6:  scan_of_raster = 4'd7;
			4'd7:  scan_of_raster = 4'd12;
			4'd8:  scan_of_raster = 4'd3;
			4'd9:  scan_of_raster = 4'd8;
			4'd10: scan_of_raster = 4'd11;
			4'd11: scan_of_raster = 4'd13;
			4'd12: scan_of_raster = 4'd9;
			4'd13: scan_of_raster = 4'd10;
			4'd14: scan_of_raster = 4'd14;
			default: scan_of_raster = 4'd15;
			endcase
		end
	endfunction

	function automatic signed [28:0] sat29;
		input signed [47:0] v;
		begin
			if (v > 48'sd268435455) sat29 = 29'sd268435455;
			else if (v < -48'sd268435456) sat29 = ~29'sd268435455;
			else sat29 = v[28:0];
		end
	endfunction

	wire [5:0] qmod6 = qp % 6;
	wire [5:0] qdiv6 = qp / 6;
	wire [2:0] qmod = qmod6[2:0];
	wire [3:0] qdiv = qdiv6[3:0];

	genvar r;
	generate
		for (r = 0; r < 16; r = r + 1) begin : g_deq
			localparam int RI = r;
			// mi counts odd raster coordinates: bit0 is the column LSB, bit2 the row LSB.
			localparam [1:0] MI = ((RI % 2) != 0 ? 2'd1 : 2'd0) +
			                      (((RI / 4) % 2) != 0 ? 2'd1 : 2'd0);
			wire [4:0] scan_idx = {1'b0, scan_of_raster(RI[3:0])};
			// AC-only blocks carry scan position n at array index n-1.
			wire [4:0] arr_idx  = skip_dc ? (scan_idx - 5'd1) : scan_idx;
			wire       in_range = skip_dc ? ((scan_idx != 5'd0) && ((scan_idx - 5'd1) < max_coeff))
			                              : (scan_idx < max_coeff);
			wire signed [15:0] c    = in_range ? coeff[arr_idx[3:0]] : 16'sd0;
			// AREA: five shifted copies of c instead of a multiplier, and the
			// LevelScale x16 folded into the rounding shift, so this instance
			// no longer claims a DSP block:
			//   ((c*na*16 << qdiv) + 32) >> 6  ==  ((c*na << qdiv) + 2) >> 2
			wire [4:0]         na  = norm_adjust(qmod, MI);
			wire signed [21:0] cw  = {{6{c[15]}}, c};
			wire signed [21:0] mul = (na[0] ? cw          : 22'sd0)
			                       + (na[1] ? (cw <<< 1)  : 22'sd0)
			                       + (na[2] ? (cw <<< 2)  : 22'sd0)
			                       + (na[3] ? (cw <<< 3)  : 22'sd0)
			                       + (na[4] ? (cw <<< 4)  : 22'sd0);
			wire signed [35:0] prod = $signed({{14{mul[21]}}, mul}) <<< qdiv;
			wire signed [35:0] rnd  = (prod + 36'sd2) >>> 2;
			wire signed [28:0] scaled = sat29({{12{rnd[35]}}, rnd});
			if (r == 0) begin : g_dc_pos
				assign dequant[r] = dc_override ? dc_value : (skip_dc ? 29'sd0 : scaled);
			end else begin : g_ac_pos
				assign dequant[r] = scaled;
			end
		end
	endgenerate
endmodule
