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

// LATENCY CONTRACT (not combinational):
//   start pulse → latch coeff+qp → 4 row Hadamard → 4 col Hadamard →
//   16 scale cycles → done=1 one cycle after last dc[] write.
//   dc[] held from done until next start. Caller holds coeff/qp stable only
//   on the start cycle (inputs latched). ~26 cycles total.
//   Consumers (must wait done — values-equal ≠ timing-equal):
//     decode_core ST_P16_RES_LDC; product i16_dc_valid after i16_ldc_done;
//     transform golden TB WaitDone. Update this header if cycle count moves.
module h264_luma_dc_hadamard_inv (
	// Intra16x16DCLevel zig-zag scan → scaled DC in residual/IDCT domain (FFmpeg).
	input  wire               clk,
	input  wire               reset,
	input  wire               start,
	input  wire signed [15:0] coeff [0:15],
	input  wire [5:0]         qp,
	output wire signed [28:0] dc [0:15],
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
	// 9-way + room for +2: shift amount 0..10
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
		default: shl_amt = {{6{v[31]}}, v, 10'b0}; // 10
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
		default: mul_norm = (c <<< 4) + (c <<< 1); // 18
		endcase
	endfunction

	// Shared 4-point Hadamard butterfly (one row or one column per cycle).
	// o0=a+b+c+d; o1=a+b-c-d; o2=a-b-c+d; o3=a-b+c-d
	function automatic signed [24:0] bf0;
		input signed [24:0] a, b, c, d;
		bf0 = a + b + c + d;
	endfunction
	function automatic signed [24:0] bf1;
		input signed [24:0] a, b, c, d;
		bf1 = a + b - c - d;
	endfunction
	function automatic signed [24:0] bf2;
		input signed [24:0] a, b, c, d;
		bf2 = a - b - c + d;
	endfunction
	function automatic signed [24:0] bf3;
		input signed [24:0] a, b, c, d;
		bf3 = a - b + c - d;
	endfunction

	// AREA: serial Hadamard (4 row + 4 col) + one scaler ×16 — was full combo
	// 16-way Hadamard + parallel scale (~3.4k ALM fit4). No `x <<< qdiv`.
	localparam [2:0] ST_IDLE  = 3'd0;
	localparam [2:0] ST_ROW   = 3'd1;
	localparam [2:0] ST_COL   = 3'd2;
	localparam [2:0] ST_SCALE = 3'd3;
	localparam [2:0] ST_DONE  = 3'd4;

	reg [2:0] st;
	reg [1:0] k;       // row or column index 0..3
	reg [3:0] idx;     // scale index 0..15
	reg [5:0] qp_r;
	reg signed [24:0] w_r [0:15]; // workspace: raster after load / row / col
	reg signed [28:0] dc_r [0:15];

	// Mux one row (ST_ROW) or one column (ST_COL) into the shared butterfly.
	wire signed [24:0] a_in = (st == ST_ROW) ? w_r[{k, 2'b00}] : w_r[{2'b00, k}];
	wire signed [24:0] b_in = (st == ST_ROW) ? w_r[{k, 2'b01}] : w_r[{2'b01, k}];
	wire signed [24:0] c_in = (st == ST_ROW) ? w_r[{k, 2'b10}] : w_r[{2'b10, k}];
	wire signed [24:0] d_in = (st == ST_ROW) ? w_r[{k, 2'b11}] : w_r[{2'b11, k}];
	wire signed [24:0] o0 = bf0(a_in, b_in, c_in, d_in);
	wire signed [24:0] o1 = bf1(a_in, b_in, c_in, d_in);
	wire signed [24:0] o2 = bf2(a_in, b_in, c_in, d_in);
	wire signed [24:0] o3 = bf3(a_in, b_in, c_in, d_in);

	// ONE scaler over 16 cycles. FFmpeg: qmul=(na*16)<<(qdiv+2); dc=(f*qmul+128)>>8
	wire [2:0] qmod = qp_mod6(qp_r);
	wire [3:0] qdiv = qp_div6(qp_r);
	wire [4:0] na   = norm_adjust0(qmod);
	wire signed [31:0] base = mul_norm({{7{w_r[idx][24]}}, w_r[idx]}, na);
	wire signed [31:0] base16 = {base[27:0], 4'b0};
	wire signed [47:0] prod = shl_amt(base16, qdiv + 4'd2);
	wire signed [28:0] scaled = sat29((prod + 48'sd128) >>> 8);

	genvar di;
	generate
		for (di = 0; di < 16; di = di + 1) begin : g_dc_out
			assign dc[di] = dc_r[di];
		end
	endgenerate

	integer ki;
	always @(posedge clk) begin
		done <= 1'b0;
		if (reset) begin
			st <= ST_IDLE;
			k <= 2'd0;
			idx <= 4'd0;
			qp_r <= 6'd0;
			for (ki = 0; ki < 16; ki = ki + 1) begin
				w_r[ki] <= 25'sd0;
				dc_r[ki] <= 29'sd0;
			end
		end else begin
			case (st)
			ST_IDLE: begin
				if (start) begin
					qp_r <= qp;
					// Latch zigzag→raster; one shared butterfly follows.
					for (ki = 0; ki < 16; ki = ki + 1)
						w_r[ki] <= {{9{coeff[scan_of_raster(ki[3:0])][15]}},
						            coeff[scan_of_raster(ki[3:0])]};
					k <= 2'd0;
					st <= ST_ROW;
				end
			end
			ST_ROW: begin
				// Write butterfly back into this row.
				w_r[{k, 2'b00}] <= o0;
				w_r[{k, 2'b01}] <= o1;
				w_r[{k, 2'b10}] <= o2;
				w_r[{k, 2'b11}] <= o3;
				if (k == 2'd3) begin
					k <= 2'd0;
					st <= ST_COL;
				end else begin
					k <= k + 2'd1;
				end
			end
			ST_COL: begin
				// Column butterfly into same workspace (Hadamard f[]).
				w_r[{2'b00, k}] <= o0;
				w_r[{2'b01, k}] <= o1;
				w_r[{2'b10, k}] <= o2;
				w_r[{2'b11, k}] <= o3;
				if (k == 2'd3) begin
					idx <= 4'd0;
					st <= ST_SCALE;
				end else begin
					k <= k + 2'd1;
				end
			end
			ST_SCALE: begin
				dc_r[idx] <= scaled;
				if (idx == 4'd15)
					st <= ST_DONE;
				else
					idx <= idx + 4'd1;
			end
			default: begin // ST_DONE
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
