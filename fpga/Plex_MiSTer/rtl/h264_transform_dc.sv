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


	// ── normAdjust product without a multiplier ─────────────────────────────
	// H.264 chose the normAdjust constants so the inverse transform needs no
	// multiplier at all: every one of the ten distinct values is a sum of at
	// most three powers of two.  Writing this as `c * na` handed Quartus a
	// 16x18 signed multiply, and it spent a DSP block on each of the sixteen
	// coefficients -- on a 5CSEBA6U23I7 with 112 DSPs that is most of the
	// device's multipliers on arithmetic that needs none.
	//
	//   10 = 8+2      11 = 8+2+1    13 = 8+4+1    14 = 16-2     16 = 16
	//   18 = 16+2     20 = 16+4     23 = 16+8-1   25 = 16+8+1   29 = 32-2-1
	//
	// The shifts are wiring, so this is three muxes and one three-input add.
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

	// Explicit mux, not `v <<< qdiv`.  Quartus's automatic DSP replacement
	// turns a variable-distance barrel shifter into a multiply by 1<<qdiv and
	// packs it into a DSP block -- that, not the normAdjust product, is where
	// sixteen DSPs per instance were actually going.  qP <= 51 bounds qdiv to
	// 0..8, so nine concatenations spell the shifter out as pure wiring plus
	// a mux tree that the DSP inference engine has no pattern for.
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

	// LevelScale(qP%6,0,0) = 16 * normAdjust(qP%6,0)
	wire [2:0] qmod = qp % 6;
	wire [3:0] qdiv = qp / 6;

	// dcY = (f * LevelScale << (qP/6) + 32) >> 6 — identical to both 8.5.10
	// branches.  LevelScale is 16 * normAdjust, so the >> 6 cancels four of
	// the six bits against that 16:
	//
	//   (f * na * 16 << qdiv + 32) >> 6  ==  ((f * na << qdiv) + 2) >> 2
	//
	// which also keeps the datapath inside 40 bits instead of 48 and shrinks
	// the barrel shifter that dominated this module's logic.
	genvar di;
	generate
		for (di = 0; di < 16; di = di + 1) begin : g_dc
			wire signed [31:0] base = mul_norm(32'(f[di]), norm_adjust0(qmod));
			wire signed [39:0] prod = shl_qdiv($signed({{8{base[31]}}, base}), qdiv);
			assign dc[di] = sat29(48'((prod + 40'sd2) >>> 2));
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


	// ── normAdjust product without a multiplier ─────────────────────────────
	// H.264 chose the normAdjust constants so the inverse transform needs no
	// multiplier at all: every one of the ten distinct values is a sum of at
	// most three powers of two.  Writing this as `c * na` handed Quartus a
	// 16x18 signed multiply, and it spent a DSP block on each of the sixteen
	// coefficients -- on a 5CSEBA6U23I7 with 112 DSPs that is most of the
	// device's multipliers on arithmetic that needs none.
	//
	//   10 = 8+2      11 = 8+2+1    13 = 8+4+1    14 = 16-2     16 = 16
	//   18 = 16+2     20 = 16+4     23 = 16+8-1   25 = 16+8+1   29 = 32-2-1
	//
	// The shifts are wiring, so this is three muxes and one three-input add.
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

	// Explicit mux, not `v <<< qdiv`.  Quartus's automatic DSP replacement
	// turns a variable-distance barrel shifter into a multiply by 1<<qdiv and
	// packs it into a DSP block -- that, not the normAdjust product, is where
	// sixteen DSPs per instance were actually going.  qP <= 51 bounds qdiv to
	// 0..8, so nine concatenations spell the shifter out as pure wiring plus
	// a mux tree that the DSP inference engine has no pattern for.
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

	wire [2:0] qmod = qp % 6;
	wire [3:0] qdiv = qp / 6;

	// dcC = ((f * LevelScale(qP%6,0,0)) << (qP/6)) >> 5   (8.5.11.2)
	// LevelScale is 16 * normAdjust, so >> 5 leaves a single >> 1.
	genvar di;
	generate
		for (di = 0; di < 4; di = di + 1) begin : g_cdc
			wire signed [31:0] base = mul_norm(32'(f[di]), norm_adjust0(qmod));
			wire signed [39:0] prod = shl_qdiv($signed({{8{base[31]}}, base}), qdiv);
			assign dc[di] = sat29(48'(prod >>> 1));
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


	// ── normAdjust product without a multiplier ─────────────────────────────
	// H.264 chose the normAdjust constants so the inverse transform needs no
	// multiplier at all: every one of the ten distinct values is a sum of at
	// most three powers of two.  Writing this as `c * na` handed Quartus a
	// 16x18 signed multiply, and it spent a DSP block on each of the sixteen
	// coefficients -- on a 5CSEBA6U23I7 with 112 DSPs that is most of the
	// device's multipliers on arithmetic that needs none.
	//
	//   10 = 8+2      11 = 8+2+1    13 = 8+4+1    14 = 16-2     16 = 16
	//   18 = 16+2     20 = 16+4     23 = 16+8-1   25 = 16+8+1   29 = 32-2-1
	//
	// The shifts are wiring, so this is three muxes and one three-input add.
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

	// Explicit mux, not `v <<< qdiv`.  Quartus's automatic DSP replacement
	// turns a variable-distance barrel shifter into a multiply by 1<<qdiv and
	// packs it into a DSP block -- that, not the normAdjust product, is where
	// sixteen DSPs per instance were actually going.  qP <= 51 bounds qdiv to
	// 0..8, so nine concatenations spell the shifter out as pure wiring plus
	// a mux tree that the DSP inference engine has no pattern for.
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

	wire [2:0] qmod = qp % 6;
	wire [3:0] qdiv = qp / 6;

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
			// 8.5.12.1 collapses to a plain shift for every qP.  With the flat
			// 4x4 weight matrix LevelScale is 16*normAdjust, so
			//   qP >= 24: (c*16*na) << (qdiv-4)                 == (c*na) << qdiv
			//   qP <  24: (c*16*na + 2**(3-qdiv)) >> (4-qdiv)   == (c*na) << qdiv
			// (the rounding term is exactly one half ULP and floors away).
			// The old form applied only a <<4 where LevelScale needs <<6, so
			// every dequantised coefficient came out four times too small --
			// the residual was there but scaled almost to nothing.
			wire signed [31:0] base = mul_norm(32'(c), norm_adjust(qmod, MI));
			wire signed [39:0] prod = shl_qdiv($signed({{8{base[31]}}, base}), qdiv);
			wire signed [28:0] scaled = sat29(48'(prod));
			if (r == 0) begin : g_dc_pos
				assign dequant[r] = dc_override ? dc_value : (skip_dc ? 29'sd0 : scaled);
			end else begin : g_ac_pos
				assign dequant[r] = scaled;
			end
		end
	endgenerate
endmodule
