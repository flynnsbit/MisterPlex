// H.264 Baseline DC transform + flexible 4x4 dequant (8.5.8–8.5.12.1).
// LevelScale domain matches h264_dequant4x4 / FFmpeg:
//   d = ((c * na * 16) << (qP/6 + 2) + 32) >> 6
// DSP trap: never `v <<< qdiv` or qp%6 / qp/6 — use qp_* LUTs + shl_qdiv mux.
// OWNER: w-residual

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

module h264_luma_dc_hadamard_inv (
	// Sequential: Hadamard combo + ONE scaler over 16 cycles. FFmpeg scale.
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	output reg  signed [28:0] dc [0:15],
	output reg                done
);
	function automatic [4:0] norm_adjust0;
		input [2:0] qmod;
		case (qmod)
		3'd0: norm_adjust0 = 5'd10;
		3'd1: norm_adjust0 = 5'd11;
		3'd2: norm_adjust0 = 5'd13;
		3'd3: norm_adjust0 = 5'd14;
		3'd4: norm_adjust0 = 5'd16;
		default: norm_adjust0 = 5'd18;
		endcase
	endfunction
	function automatic [3:0] scan_of_raster;
		input [3:0] r;
		case (r)
		4'd0: scan_of_raster = 4'd0;   4'd1: scan_of_raster = 4'd1;
		4'd2: scan_of_raster = 4'd5;   4'd3: scan_of_raster = 4'd6;
		4'd4: scan_of_raster = 4'd2;   4'd5: scan_of_raster = 4'd4;
		4'd6: scan_of_raster = 4'd7;   4'd7: scan_of_raster = 4'd12;
		4'd8: scan_of_raster = 4'd3;   4'd9: scan_of_raster = 4'd8;
		4'd10: scan_of_raster = 4'd11; 4'd11: scan_of_raster = 4'd13;
		4'd12: scan_of_raster = 4'd9;  4'd13: scan_of_raster = 4'd10;
		4'd14: scan_of_raster = 4'd14; default: scan_of_raster = 4'd15;
		endcase
	endfunction
	function automatic signed [28:0] sat29;
		input signed [47:0] v;
		if (v > 48'sd268435455) sat29 = 29'sd268435455;
		else if (v < -48'sd268435456) sat29 = ~29'sd268435455;
		else sat29 = v[28:0];
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
	function automatic signed [31:0] mul_norm;
		input signed [31:0] c;
		input [4:0] na;
		case (na)
		5'd10: mul_norm = (c <<< 3) + (c <<< 1);
		5'd11: mul_norm = (c <<< 3) + (c <<< 1) + c;
		5'd13: mul_norm = (c <<< 3) + (c <<< 2) + c;
		5'd14: mul_norm = (c <<< 4) - (c <<< 1);
		5'd16: mul_norm = (c <<< 4);
		default: mul_norm = (c <<< 4) + (c <<< 1);
		endcase
	endfunction

	wire signed [20:0] c [0:15];
	genvar zi;
	generate
		for (zi = 0; zi < 16; zi = zi + 1) begin : g_izz
			localparam int ZI = zi;
			assign c[zi] = $signed(coeff[scan_of_raster(ZI[3:0])]);
		end
	endgenerate

	wire signed [22:0] g0  = c[0]+c[1]+c[2]+c[3];
	wire signed [22:0] g1  = c[0]+c[1]-c[2]-c[3];
	wire signed [22:0] g2  = c[0]-c[1]-c[2]+c[3];
	wire signed [22:0] g3  = c[0]-c[1]+c[2]-c[3];
	wire signed [22:0] g4  = c[4]+c[5]+c[6]+c[7];
	wire signed [22:0] g5  = c[4]+c[5]-c[6]-c[7];
	wire signed [22:0] g6  = c[4]-c[5]-c[6]+c[7];
	wire signed [22:0] g7  = c[4]-c[5]+c[6]-c[7];
	wire signed [22:0] g8  = c[8]+c[9]+c[10]+c[11];
	wire signed [22:0] g9  = c[8]+c[9]-c[10]-c[11];
	wire signed [22:0] g10 = c[8]-c[9]-c[10]+c[11];
	wire signed [22:0] g11 = c[8]-c[9]+c[10]-c[11];
	wire signed [22:0] g12 = c[12]+c[13]+c[14]+c[15];
	wire signed [22:0] g13 = c[12]+c[13]-c[14]-c[15];
	wire signed [22:0] g14 = c[12]-c[13]-c[14]+c[15];
	wire signed [22:0] g15 = c[12]-c[13]+c[14]-c[15];

	wire signed [24:0] f_w [0:15];
	assign f_w[0]  = g0+g4+g8+g12;  assign f_w[1]  = g1+g5+g9+g13;
	assign f_w[2]  = g2+g6+g10+g14; assign f_w[3]  = g3+g7+g11+g15;
	assign f_w[4]  = g0+g4-g8-g12;  assign f_w[5]  = g1+g5-g9-g13;
	assign f_w[6]  = g2+g6-g10-g14; assign f_w[7]  = g3+g7-g11-g15;
	assign f_w[8]  = g0-g4-g8+g12;  assign f_w[9]  = g1-g5-g9+g13;
	assign f_w[10] = g2-g6-g10+g14; assign f_w[11] = g3-g7-g11+g15;
	assign f_w[12] = g0-g4+g8-g12;  assign f_w[13] = g1-g5+g9-g13;
	assign f_w[14] = g2-g6+g10-g14; assign f_w[15] = g3-g7+g11-g15;

	reg [1:0] st;
	reg [3:0] idx;
	reg [5:0] qp_r;
	reg signed [24:0] f_r [0:15];
	localparam [1:0] ST_IDLE=2'd0, ST_SCALE=2'd1, ST_DONE=2'd2;

	wire [2:0] qmod = qp_mod6(qp_r);
	wire [3:0] qdiv = qp_div6(qp_r);
	wire [4:0] na = norm_adjust0(qmod);
	wire signed [31:0] base = mul_norm({{7{f_r[idx][24]}}, f_r[idx]}, na);
	wire signed [31:0] base16 = {base[27:0], 4'b0};
	wire signed [47:0] prod = shl_amt(base16, qdiv + 4'd2);
	wire signed [28:0] scaled = sat29((prod + 48'sd128) >>> 8);

	integer k;
	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st <= ST_IDLE; idx <= 0; qp_r <= 0;
			for (k = 0; k < 16; k = k + 1) begin
				dc[k] <= 0; f_r[k] <= 0;
			end
		end else begin
			case (st)
			ST_IDLE: if (start) begin
				for (k = 0; k < 16; k = k + 1) f_r[k] <= f_w[k];
				qp_r <= qp; idx <= 0; st <= ST_SCALE;
			end
			ST_SCALE: begin
				dc[idx] <= scaled;
				if (idx == 4'd15) st <= ST_DONE;
				else idx <= idx + 4'd1;
			end
			default: begin
				done <= 1'b1;
				st <= ST_IDLE;
			end
			endcase
		end
	end
endmodule

// 8.5.12.1 flex: inv zig-zag + LevelScale; skip_dc / dc_override for I16 AC.
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
		case ({qmod, mi})
		5'd0:  norm_adjust = 5'd10; 5'd1:  norm_adjust = 5'd13; 5'd2:  norm_adjust = 5'd16;
		5'd4:  norm_adjust = 5'd11; 5'd5:  norm_adjust = 5'd14; 5'd6:  norm_adjust = 5'd18;
		5'd8:  norm_adjust = 5'd13; 5'd9:  norm_adjust = 5'd16; 5'd10: norm_adjust = 5'd20;
		5'd12: norm_adjust = 5'd14; 5'd13: norm_adjust = 5'd18; 5'd14: norm_adjust = 5'd23;
		5'd16: norm_adjust = 5'd16; 5'd17: norm_adjust = 5'd20; 5'd18: norm_adjust = 5'd25;
		5'd20: norm_adjust = 5'd18; 5'd21: norm_adjust = 5'd23; default: norm_adjust = 5'd29;
		endcase
	endfunction
	function automatic [3:0] scan_of_raster;
		input [3:0] r;
		case (r)
		4'd0: scan_of_raster = 4'd0;   4'd1: scan_of_raster = 4'd1;
		4'd2: scan_of_raster = 4'd5;   4'd3: scan_of_raster = 4'd6;
		4'd4: scan_of_raster = 4'd2;   4'd5: scan_of_raster = 4'd4;
		4'd6: scan_of_raster = 4'd7;   4'd7: scan_of_raster = 4'd12;
		4'd8: scan_of_raster = 4'd3;   4'd9: scan_of_raster = 4'd8;
		4'd10: scan_of_raster = 4'd11; 4'd11: scan_of_raster = 4'd13;
		4'd12: scan_of_raster = 4'd9;  4'd13: scan_of_raster = 4'd10;
		4'd14: scan_of_raster = 4'd14; default: scan_of_raster = 4'd15;
		endcase
	endfunction
	function automatic signed [28:0] sat29;
		input signed [47:0] v;
		if (v > 48'sd268435455) sat29 = 29'sd268435455;
		else if (v < -48'sd268435456) sat29 = ~29'sd268435455;
		else sat29 = v[28:0];
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
		default: mul_norm = (c <<< 5) - (c <<< 1) - c; // 29
		endcase
	endfunction

	wire [2:0] qmod = qp_mod6(qp);
	wire [3:0] qdiv = qp_div6(qp);

	genvar r;
	generate
		for (r = 0; r < 16; r = r + 1) begin : g_deq
			localparam int RI = r;
			localparam [1:0] MI = ((RI % 2) != 0 ? 2'd1 : 2'd0) +
			                      (((RI / 4) % 2) != 0 ? 2'd1 : 2'd0);
			wire [4:0] scan_idx = {1'b0, scan_of_raster(RI[3:0])};
			wire [4:0] arr_idx  = skip_dc ? (scan_idx - 5'd1) : scan_idx;
			wire       in_range = skip_dc ? ((scan_idx != 5'd0) && ((scan_idx - 5'd1) < max_coeff))
			                              : (scan_idx < max_coeff);
			wire signed [15:0] c  = in_range ? coeff[arr_idx[3:0]] : 16'sd0;
			wire [4:0]         na = norm_adjust(qmod, MI);
			// (c*na*16) << (qdiv+2) + 32) >> 6  — FFmpeg / 4e0770b flex fix
			wire signed [31:0] base   = mul_norm({{16{c[15]}}, c}, na);
			wire signed [31:0] base16 = {base[27:0], 4'b0}; // *16
			wire signed [47:0] prod   = shl_amt(base16, qdiv + 4'd2);
			wire signed [47:0] rnd    = (prod + 48'sd32) >>> 6;
			wire signed [28:0] scaled = sat29(rnd);
			if (r == 0) begin : g_dc_pos
				assign dequant[r] = dc_override ? dc_value : (skip_dc ? 29'sd0 : scaled);
			end else begin : g_ac_pos
				assign dequant[r] = scaled;
			end
		end
	endgenerate
endmodule
