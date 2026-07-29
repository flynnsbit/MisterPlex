// h264_iq_idct_seq — sequential 4x4 inverse scale + inverse transform.
//
// Bit-exact replacement for h264_dequant4x4_flex + h264_idct4x4 (~21 cycles).
// LevelScale MUST match flex / FFmpeg 8.5.12.1 exactly (not the collapsed form):
//   d = ((c * na * 16) << (qdiv + 2) + 32) >> 6
// Do NOT simplify to (c*na)<<qdiv in RTL comments or code — three prior copies
// each drifted independently.  DSP trap: never `v <<< qdiv` or qp%/qp/; use
// qp_mod6/qp_div6 LUTs + mul_norm + 48-bit shl_amt mux (amt = qdiv+2, 0..10).
`default_nettype none

module h264_iq_idct_seq (
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	input  wire [4:0]         max_coeff,
	input  wire               skip_dc,
	input  wire               dc_override,
	input  wire signed [28:0] dc_value,
	output wire signed [28:0] residual [0:15],
	output reg                done
);
	function automatic [4:0] norm_adjust;
		input [2:0] qmod_i;
		input [1:0] mi;
		begin
			case ({qmod_i, mi})
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
			4'd0:  scan_of_raster = 4'd0;  4'd1:  scan_of_raster = 4'd1;
			4'd2:  scan_of_raster = 4'd5;  4'd3:  scan_of_raster = 4'd6;
			4'd4:  scan_of_raster = 4'd2;  4'd5:  scan_of_raster = 4'd4;
			4'd6:  scan_of_raster = 4'd7;  4'd7:  scan_of_raster = 4'd12;
			4'd8:  scan_of_raster = 4'd3;  4'd9:  scan_of_raster = 4'd8;
			4'd10: scan_of_raster = 4'd11; 4'd11: scan_of_raster = 4'd13;
			4'd12: scan_of_raster = 4'd9;  4'd13: scan_of_raster = 4'd10;
			4'd14: scan_of_raster = 4'd14; default: scan_of_raster = 4'd15;
			endcase
		end
	endfunction

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
			default:                             qp_div6 = 4'd8;
			endcase
		end
	endfunction

	// 48-bit shift mux for (qdiv+2) in 0..10 — identical to flex. Never `v <<< q`.
	function automatic signed [47:0] shl_amt;
		input signed [31:0] v;
		input [3:0] amt;
		begin
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
			default: shl_amt = {{6{v[31]}}, v, 10'b0}; // amt==10
			endcase
		end
	endfunction

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
			default: mul_norm = (c <<< 5) - (c <<< 1) - c;
			endcase
		end
	endfunction

	function automatic signed [28:0] sat29;
		input signed [47:0] v;
		begin
			if (v > 48'sd268435455)       sat29 = 29'sd268435455;
			else if (v < -48'sd268435456) sat29 = ~29'sd268435455;
			else                          sat29 = v[28:0];
		end
	endfunction

	localparam [1:0] ST_IDLE = 2'd0, ST_SCALE = 2'd1, ST_COL = 2'd2, ST_DONE = 2'd3;

	reg [1:0] st;
	reg [3:0] cnt;

	wire [2:0] qmod = qp_mod6(qp);
	wire [3:0] qdiv = qp_div6(qp);

	wire [3:0] r     = cnt;
	wire [1:0] mi    = {1'b0, r[0]} + {1'b0, r[2]};
	wire [4:0] scan5 = {1'b0, scan_of_raster(r)};
	wire [4:0] arr5  = skip_dc ? (scan5 - 5'd1) : scan5;
	wire in_range    = skip_dc ? ((scan5 != 5'd0) && ((scan5 - 5'd1) < max_coeff))
	                           : (scan5 < max_coeff);

	wire signed [15:0] cval = in_range ? coeff[arr5[3:0]] : 16'sd0;
	wire [4:0]         na   = norm_adjust(qmod, mi);

	// LevelScale identical to h264_dequant4x4_flex (4e0770b / FFmpeg):
	//   ((c * na * 16) << (qdiv + 2) + 32) >> 6
	wire signed [31:0] base   = mul_norm({{16{cval[15]}}, cval}, na);
	wire signed [31:0] base16 = {base[27:0], 4'b0}; // *16
	wire signed [47:0] prod   = shl_amt(base16, qdiv + 4'd2);
	wire signed [47:0] rnd    = (prod + 48'sd32) >>> 6;
	wire signed [28:0] scaled = sat29(rnd);
	wire signed [28:0] dq_val = (r == 4'd0) ? (dc_override ? dc_value
	                                                        : (skip_dc ? 29'sd0 : scaled))
	                                         : scaled;
	// IDCT rounding constant on raster position 0 only (matches h264_idct4x4).
	wire signed [31:0] b_in = $signed({{3{dq_val[28]}}, dq_val}) +
	                          ((r == 4'd0) ? 32'sd32 : 32'sd0);

	reg  signed [31:0] rb0, rb1, rb2;
	reg  signed [31:0] a [0:15];

	wire row_push = (st == ST_SCALE) && (cnt[1:0] == 2'd3);

	wire signed [31:0] f0 = row_push ? rb0 : a[0];
	wire signed [31:0] f1 = row_push ? rb1 : a[4];
	wire signed [31:0] f2 = row_push ? rb2 : a[8];
	wire signed [31:0] f3 = row_push ? b_in : a[12];

	wire signed [31:0] z0 = f0 + f2;
	wire signed [31:0] z1 = f0 - f2;
	wire signed [31:0] z2 = (f1 >>> 1) - f3;
	wire signed [31:0] z3 = f1 + (f3 >>> 1);

	wire signed [31:0] o0 = z0 + z3;
	wire signed [31:0] o1 = z1 + z2;
	wire signed [31:0] o2 = z1 - z2;
	wire signed [31:0] o3 = z0 - z3;

	reg signed [28:0] o [0:15];

	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_out
			assign residual[gi] = o[gi];
		end
	endgenerate

	integer k;
	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st  <= ST_IDLE;
			cnt <= 4'd0;
			rb0 <= 32'sd0; rb1 <= 32'sd0; rb2 <= 32'sd0;
			for (k = 0; k < 16; k = k + 1) begin
				a[k] <= 32'sd0;
				o[k] <= 29'sd0;
			end
		end else begin
			case (st)
				ST_IDLE: if (start) begin
					cnt <= 4'd0;
					st  <= ST_SCALE;
				end

				ST_SCALE: begin
					rb0 <= rb1;
					rb1 <= rb2;
					rb2 <= b_in;
					cnt <= cnt + 4'd1;
					if (cnt == 4'd15) begin
						cnt <= 4'd0;
						st  <= ST_COL;
					end
				end

				ST_COL: begin
					cnt <= cnt + 4'd1;
					if (cnt == 4'd3) begin
						cnt <= 4'd0;
						st  <= ST_DONE;
					end
				end

				default: begin
					done <= 1'b1;
					st   <= ST_IDLE;
				end
			endcase

			if (st == ST_SCALE || st == ST_COL) begin
				for (k = 0; k < 12; k = k + 1)
					a[k] <= a[k+1];
				if (row_push) begin
					a[12] <= o0;
					a[13] <= o1;
					a[14] <= o2;
					a[15] <= o3;
				end else begin
					a[12] <= a[13];
					a[13] <= a[14];
					a[14] <= a[15];
					a[15] <= a[0];
				end
			end

			if (st == ST_COL) begin
				for (k = 0; k < 16; k = k + 1) begin
					if (k == 3)       o[k] <= sat29(o0 >>> 6);
					else if (k == 7)  o[k] <= sat29(o1 >>> 6);
					else if (k == 11) o[k] <= sat29(o2 >>> 6);
					else if (k == 15) o[k] <= sat29(o3 >>> 6);
					else              o[k] <= o[k+1];
				end
			end
		end
	end
endmodule

`default_nettype wire
