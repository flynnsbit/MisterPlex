// present_scale_4_3_2ppc — product 4/3 dual-destination-pixel (2-PPC) engine.
//
// rd-duck: single-pixel mapper alone is NOT a load-bearing scaler. w-clock's
// path emits 2 glass pixels per group; 4/3 pairs need up to 3 unique H taps
// and 2 V lines, then real lerp. This module is that path.
//
// Pair geometry (dst base even hc_g = 2k):
//   {0,1}: floors {0,0} → H taps base..base+1 (2 unique)
//   {2,3}: floors {1,2} → H taps base..base+2 (3 unique)
//   repeats every 4 dst columns. V shared (same py).
//
// Tap window contract (caller / TB / future ddr_frame_store):
//   tap_base_x = min(floor(hc_g), floor(hc_g+1))
//   tap_y0[i] = src[tap_base_x+i][y0]   i=0..3  (4 is enough for any pair)
//   tap_y1[i] = src[tap_base_x+i][y1]
//   Samples past SRC_W-1 must be clamped by the caller (or equal last).
//
// Weights: sum-256 (9-bit). out = (· + 128) >> 8 — constant-color exact.
// Phase = (3·dst) mod 4 via num[1:0]. FAULT_PHASE_DST → dst[1:0] (must RED).
//
// Default OFF — not wired into present_core until w-clock 2-PPC bridge + w-mem
// storage/canvas split land. Sim proves pixel raster; fit stays NN/off.
//
// Cost: 0 M10K here (taps are inputs). ~8 8×9 muls comb or 1-stage reg.
// Fmax: fine @29.7 MHz clk_pix — no divide on pixel path.

`default_nettype none

module present_scale_4_3_2ppc #(
	parameter int SRC_W = 960,
	parameter int SRC_H = 540,
	parameter int DST_W = 1280,
	parameter int DST_H = 720
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	// Group base: even glass X of the 2-pixel pair (hc_g, hc_g+1).
	input  wire [10:0] hc_g,
	input  wire [10:0] py,
	input  wire        in_content,
	// 4×2 tap window at tap_base_x (see header).
	input  wire [7:0]  tap_y0_0,
	input  wire [7:0]  tap_y0_1,
	input  wire [7:0]  tap_y0_2,
	input  wire [7:0]  tap_y0_3,
	input  wire [7:0]  tap_y1_0,
	input  wire [7:0]  tap_y1_1,
	input  wire [7:0]  tap_y1_2,
	input  wire [7:0]  tap_y1_3,
	// Diagnostics / consumer wiring
	output reg  [10:0] tap_base_x,
	output reg  [10:0] store_x0,
	output reg  [10:0] store_x1_a, // ceil for pix0 (name avoids clash with pair)
	output reg  [10:0] store_x0_b, // floor for pix1
	output reg  [10:0] store_x1_b,
	output reg  [10:0] store_y0,
	output reg  [10:0] store_y1,
	output reg  [1:0]  phase_x0,
	output reg  [1:0]  phase_x1,
	output reg  [1:0]  phase_y,
	output reg  [8:0]  wx0_a,
	output reg  [8:0]  wx1_a,
	output reg  [8:0]  wx0_b,
	output reg  [8:0]  wx1_b,
	output reg  [8:0]  wy0,
	output reg  [8:0]  wy1,
	output reg  [7:0]  pix0,
	output reg  [7:0]  pix1,
	output reg         de_r,
	output reg         out_valid
);
	localparam bit RATIO_W_OK = (SRC_W * 4 == DST_W * 3);
	localparam bit RATIO_H_OK = (SRC_H * 4 == DST_H * 3);
	localparam [10:0] SRC_X_LAST = 11'(SRC_W - 1);
	localparam [10:0] SRC_Y_LAST = 11'(SRC_H - 1);

	// Force even group base.
	wire [10:0] hc0 = {hc_g[10:1], 1'b0};
	wire [10:0] hc1 = hc0 + 11'd1;

`ifdef PRESENT_SCALE_4_3_FAULT_INVERT
	wire [13:0] x0_num = {3'd0, hc0} * 14'd4;
	wire [13:0] x1_num = {3'd0, hc1} * 14'd4;
	wire [13:0] y_num  = {3'd0, py}  * 14'd4;
`else
	wire [13:0] x0_num = {3'd0, hc0} * 14'd3;
	wire [13:0] x1_num = {3'd0, hc1} * 14'd3;
	wire [13:0] y_num  = {3'd0, py}  * 14'd3;
`endif

	wire [10:0] sx0_raw = x0_num[13:2];
	wire [10:0] sx1_raw = x1_num[13:2];
	wire [10:0] sy_raw  = y_num[13:2];
	wire [10:0] sx0_f = (sx0_raw > SRC_X_LAST) ? SRC_X_LAST : sx0_raw;
	wire [10:0] sx1_f = (sx1_raw > SRC_X_LAST) ? SRC_X_LAST : sx1_raw;
	wire [10:0] sy_f  = (sy_raw  > SRC_Y_LAST) ? SRC_Y_LAST : sy_raw;
	wire [10:0] sx0_c = (sx0_f >= SRC_X_LAST) ? SRC_X_LAST : (sx0_f + 11'd1);
	wire [10:0] sx1_c = (sx1_f >= SRC_X_LAST) ? SRC_X_LAST : (sx1_f + 11'd1);
	wire [10:0] sy_c  = (sy_f  >= SRC_Y_LAST) ? SRC_Y_LAST : (sy_f  + 11'd1);

`ifdef PRESENT_SCALE_4_3_FAULT_PHASE_DST
	wire [1:0] ph_x0 = hc0[1:0];
	wire [1:0] ph_x1 = hc1[1:0];
	wire [1:0] ph_y  = py[1:0];
`elsif PRESENT_SCALE_4_3_FAULT_PHASE_OBO
	wire [1:0] ph_x0 = hc0[1:0];
	wire [1:0] ph_x1 = hc1[1:0];
	wire [1:0] ph_y  = py[1:0];
`else
	wire [1:0] ph_x0 = x0_num[1:0];
	wire [1:0] ph_x1 = x1_num[1:0];
	wire [1:0] ph_y  = y_num[1:0];
`endif

	// Sum-256 ROM (9-bit). phase → (w0,w1).
	function automatic [17:0] wrom;
		input [1:0] ph;
		begin
			case (ph)
				2'd0: wrom = {9'd256, 9'd0};
				2'd1: wrom = {9'd192, 9'd64};
				2'd2: wrom = {9'd128, 9'd128};
				default: wrom = {9'd64, 9'd192};
			endcase
		end
	endfunction

	wire [17:0] wx_a = wrom(ph_x0);
	wire [17:0] wx_b = wrom(ph_x1);
	wire [17:0] wy_p = wrom(ph_y);
	wire [8:0] wx0a = wx_a[17:9];
	wire [8:0] wx1a = wx_a[8:0];
	wire [8:0] wx0b = wx_b[17:9];
	wire [8:0] wx1b = wx_b[8:0];
	wire [8:0] wy0w = wy_p[17:9];
	wire [8:0] wy1w = wy_p[8:0];

	wire [10:0] base_x = (sx0_f <= sx1_f) ? sx0_f : sx1_f;

	// Local index into 4-wide window (base ≤ sx ≤ base+2 interior).
	wire [10:0] off0 = sx0_f - base_x;
	wire [10:0] off1 = sx1_f - base_x;
	wire [1:0] ix0 = off0[1:0];
	wire [1:0] ix1 = off1[1:0];

	function automatic [7:0] pick4;
		input [1:0] ix;
		input [7:0] t0, t1, t2, t3;
		begin
			case (ix)
				2'd0: pick4 = t0;
				2'd1: pick4 = t1;
				2'd2: pick4 = t2;
				default: pick4 = t3;
			endcase
		end
	endfunction

	// ix+1 as 2-bit saturating (window is only 4 deep; edge uses floor==ceil).
	wire [1:0] ix0p = (off0 >= 11'd3) ? 2'd3 : 2'(off0[1:0] + 2'd1);
	wire [1:0] ix1p = (off1 >= 11'd3) ? 2'd3 : 2'(off1[1:0] + 2'd1);

	wire [7:0] a_p00 = pick4(ix0, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] a_p10 = pick4(ix0p, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] a_p01 = pick4(ix0, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] a_p11 = pick4(ix0p, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	// When sx0_f == SRC_X_LAST, ceil==floor — force p10=p00.
	wire [7:0] a_p10c = (sx0_f == sx0_c) ? a_p00 : a_p10;
	wire [7:0] a_p11c = (sx0_f == sx0_c) ? a_p01 : a_p11;

	wire [7:0] b_p00 = pick4(ix1, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] b_p10 = pick4(ix1p, tap_y0_0, tap_y0_1, tap_y0_2, tap_y0_3);
	wire [7:0] b_p01 = pick4(ix1, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] b_p11 = pick4(ix1p, tap_y1_0, tap_y1_1, tap_y1_2, tap_y1_3);
	wire [7:0] b_p10c = (sx1_f == sx1_c) ? b_p00 : b_p10;
	wire [7:0] b_p11c = (sx1_f == sx1_c) ? b_p01 : b_p11;

	// 2×2 bilin, sum-256 weights, round >>8 each axis:
	//   h0 = (p00*wx0 + p10*wx1 + 128) >> 8
	//   h1 = (p01*wx0 + p11*wx1 + 128) >> 8
	//   o  = (h0*wy0 + h1*wy1 + 128) >> 8
	function automatic [7:0] bilin256;
		input [7:0] p00, p10, p01, p11;
		input [8:0] wx0, wx1, wy0i, wy1i;
		reg [17:0] h0a, h1a;
		reg [7:0] h0, h1;
		reg [17:0] oa;
		begin
			h0a = p00 * wx0 + p10 * wx1 + 18'd128;
			h1a = p01 * wx0 + p11 * wx1 + 18'd128;
			h0 = h0a[15:8];
			h1 = h1a[15:8];
			oa = h0 * wy0i + h1 * wy1i + 18'd128;
			bilin256 = oa[15:8];
		end
	endfunction

	wire [7:0] pix0_w = bilin256(a_p00, a_p10c, a_p01, a_p11c, wx0a, wx1a, wy0w, wy1w);
	wire [7:0] pix1_w = bilin256(b_p00, b_p10c, b_p01, b_p11c, wx0b, wx1b, wy0w, wy1w);

	always @(posedge clk) begin
		if (reset) begin
			tap_base_x <= 0;
			store_x0 <= 0; store_x1_a <= 0; store_x0_b <= 0; store_x1_b <= 0;
			store_y0 <= 0; store_y1 <= 0;
			phase_x0 <= 0; phase_x1 <= 0; phase_y <= 0;
			wx0_a <= 9'd256; wx1_a <= 9'd0;
			wx0_b <= 9'd256; wx1_b <= 9'd0;
			wy0 <= 9'd256; wy1 <= 9'd0;
			pix0 <= 0; pix1 <= 0;
			de_r <= 0; out_valid <= 0;
		end else if (ce_pix) begin
			de_r <= in_content;
			out_valid <= in_content;
			tap_base_x <= base_x;
			store_x0 <= sx0_f;
			store_x1_a <= sx0_c;
			store_x0_b <= sx1_f;
			store_x1_b <= sx1_c;
			store_y0 <= sy_f;
			store_y1 <= sy_c;
			phase_x0 <= ph_x0;
			phase_x1 <= ph_x1;
			phase_y <= ph_y;
			wx0_a <= wx0a; wx1_a <= wx1a;
			wx0_b <= wx0b; wx1_b <= wx1b;
			wy0 <= wy0w; wy1 <= wy1w;
			pix0 <= pix0_w;
			pix1 <= pix1_w;
		end
	end

	wire ratio_pin = RATIO_W_OK & RATIO_H_OK;
	// synthesis translate_off
	initial if (!ratio_pin) $error("present_scale_4_3_2ppc: SRC/DST not exact 4/3");
	// synthesis translate_on
endmodule

`default_nettype wire
