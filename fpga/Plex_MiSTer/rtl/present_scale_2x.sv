// present_scale_2x — exact integer 2× (product TV tier: 640×360 → 1280×720).
//
// Parent frame-rate fork:
//   23.976/24 film  → 960×540 + present_scale_4_3 (detail)
//   29.97/30 TV     → 640×360 + THIS path (motion, no judder, no soft)
//
// Exact 2× means pure replication — no phase, no coefficient ROM, no (3·dst)mod4.
// Classes of bug that bit 4/3 (dst-mod-4 weight swap) **cannot exist** here.
//
// Mapping:
//   store_x = hc >> 1;   // dst 0,1 → src 0;  2,3 → 1; ... 1278,1279 → 639
//   store_y = py >> 1;   // 720 → 360
//   store_x1 = store_x; store_y1 = store_y;  // NN — no second tap
//   wx0=256, wx1=0, wy0=256, wy1=0         // sum-256 NN (constant exact)
//
// vs general present_content_window:
//   General NN with content=640, DE=1280 yields the same floors via Q16
//   (sx=32768 → hc*32768>>16 = hc>>1). So general *can* do 2× today.
//   This module still earns a seat because:
//     (1) 0 muls on pixel path (wire shift) vs 20b Q16 mul every pixel
//     (2) bilinear macro cannot accidentally soften 2× (frac forced NN)
//     (3) runtime tier select is explicit — no PLXG dim footgun
//
// Cost: ~0 M10K, 0 DSP, handful of ALMs (shift+reg). Coexist with 4/3 freely.
// Default OFF: `PRESENT_SCALE_2X`.
// FAULT: PRESENT_SCALE_2X_FAULT_IDENTITY  — store=dst (must RED mid≠319)
//        PRESENT_SCALE_2X_FAULT_PLUS1     — (dst+1)>>1 off-by-one

`default_nettype none

module present_scale_2x #(
	parameter int SRC_W = 640,
	parameter int SRC_H = 360,
	parameter int DST_W = 1280,
	parameter int DST_H = 720
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [10:0] hc,
	input  wire [10:0] py,
	input  wire        in_content,
	output reg  [10:0] store_x,
	output reg  [10:0] store_y,
	output reg  [10:0] store_x1,
	output reg  [10:0] store_y1,
	// NN weights (sum-256) — always pure left/top sample
	output reg  [8:0]  wx0,
	output reg  [8:0]  wx1,
	output reg  [8:0]  wy0,
	output reg  [8:0]  wy1,
	output reg         de_r
);
	localparam bit RATIO_W_OK = (SRC_W * 2 == DST_W);
	localparam bit RATIO_H_OK = (SRC_H * 2 == DST_H);
	localparam [10:0] SRC_X_LAST = 11'(SRC_W - 1);
	localparam [10:0] SRC_Y_LAST = 11'(SRC_H - 1);

`ifdef PRESENT_SCALE_2X_FAULT_IDENTITY
	// FAULT: no scale — glass coords as store (mid 639 not 319)
	wire [10:0] sx_raw = hc;
	wire [10:0] sy_raw = py;
`elsif PRESENT_SCALE_2X_FAULT_PLUS1
	// FAULT: off-by-one before shift
	wire [10:0] sx_raw = (hc + 11'd1) >> 1;
	wire [10:0] sy_raw = (py + 11'd1) >> 1;
`else
	wire [10:0] sx_raw = hc >> 1;
	wire [10:0] sy_raw = py >> 1;
`endif
	wire [10:0] sx = (sx_raw > SRC_X_LAST) ? SRC_X_LAST : sx_raw;
	wire [10:0] sy = (sy_raw > SRC_Y_LAST) ? SRC_Y_LAST : sy_raw;

	always @(posedge clk) begin
		if (reset) begin
			store_x <= 0; store_y <= 0;
			store_x1 <= 0; store_y1 <= 0;
			wx0 <= 9'd256; wx1 <= 9'd0;
			wy0 <= 9'd256; wy1 <= 9'd0;
			de_r <= 0;
		end else if (ce_pix) begin
			de_r <= in_content;
			store_x <= sx;
			store_y <= sy;
			store_x1 <= sx; // NN: no ceil tap
			store_y1 <= sy;
			wx0 <= 9'd256; wx1 <= 9'd0;
			wy0 <= 9'd256; wy1 <= 9'd0;
		end
	end

	wire ratio_pin = RATIO_W_OK & RATIO_H_OK;
	// synthesis translate_off
	initial if (!ratio_pin) $error("present_scale_2x: SRC/DST not exact 2x");
	// synthesis translate_on
endmodule

`default_nettype wire
