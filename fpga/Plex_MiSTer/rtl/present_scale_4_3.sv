// present_scale_4_3 — product-path 960×540 → 1280×720 (exact 4/3 both axes).
//
// Parent ship path (measured): ARM decodes 960×540 (~34.5 ms with copy), fabric
// emits native 1280×720 OUTPUT. Scale is exactly 4/3 — rational, not general.
//
// CODED vs DISPLAY (parent SPS + libavcodec measurement — SETTLED):
//   Product ARM path: libavcodec already crops SPS bottom-4 → AVFrame 960×540.
//   Bank publish = 777600 B. SRC_H=540, exact 4/3 → 720. **No fabric V-crop.**
//   SPS coded height is 544 (pic_height_in_map_units=33+1); that matters only
//   for bitstream-ring / fabric-decoder consumers, not this scaler on ARM path.
//   Never set SRC_H=544 (would yield ~725.3 glass lines — "quality" false RCA).
//
//   src = dst * 3 / 4     (integer; dst=1279 → src=959 exact)
//   phase = dst[1:0]      // 0,1,2,3 → frac 0, 1/4, 1/2, 3/4 repeating
//
// No runtime division on the pixel path: *3 is shift-add, /4 is >>2.
// Bilinear weights live in a 4-entry ROM (phase → wx0/wx1). Vertical same.
//
// Quality (honest):
//   H 2-tap bilinear: cheap, enough at 4/3.
//   V 2-tap bilinear: ship default — usually OK for decoded video; residual
//     line-twitter possible on high-contrast horizontal detail in motion.
//   V 4-tap (`PRESENT_SCALE_4_3_VTAPS4`): Catmull-Rom-ish taps in ROM;
//     needs 4 source lines held ≈ 4×960 B ≈ 2–4 M10K. Enable if glass twitters.
//
// Cost:
//   NN 4/3:       0 M10K, 0 DSP, *3>>2     — trivial @29.7 MHz clk_pix
//   biline 2-tap: 0 M10K (+2 dual-Y hold)  — OK @29.7/74
//   V 4-tap:      +2..4 M10K               — OK @29.7; optional
//
// clk_pix / DE: w-clock owns glass H_DE=1280 @ ~29.7 MHz for 720p24 CEA.
// hc/py = beam glass_x0/y. store_* = bank coords (w-scaler). Not Template 529.
//
// Default OFF: instantiate only under `PRESENT_SCALE_4_3`.
// FAULT: PRESENT_SCALE_4_3_FAULT_INVERT, PRESENT_SCALE_4_3_FAULT_PHASE_OBO.

`default_nettype none

module present_scale_4_3 #(
	parameter int SRC_W = 960,
	parameter int SRC_H = 540,
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
	output reg  [1:0]  phase_x,
	output reg  [1:0]  phase_y,
	output reg  [7:0]  wx0,
	output reg  [7:0]  wx1,
	output reg  [7:0]  wy0,
	output reg  [7:0]  wy1,
`ifdef PRESENT_SCALE_4_3_VTAPS4
	output reg  signed [7:0] vt0,
	output reg  signed [7:0] vt1,
	output reg  signed [7:0] vt2,
	output reg  signed [7:0] vt3,
	output reg  [10:0] store_y_m1,
	output reg  [10:0] store_y_p2,
`endif
	output reg         de_r
);
	localparam bit RATIO_W_OK = (SRC_W * 4 == DST_W * 3);
	localparam bit RATIO_H_OK = (SRC_H * 4 == DST_H * 3);
	localparam [10:0] SRC_X_LAST = 11'(SRC_W - 1);
	localparam [10:0] SRC_Y_LAST = 11'(SRC_H - 1);

`ifdef PRESENT_SCALE_4_3_FAULT_INVERT
	// *4>>2 ≈ identity — not 4/3 upscale (red twin).
	wire [13:0] x_num = {3'd0, hc} * 14'd4;
	wire [13:0] y_num = {3'd0, py} * 14'd4;
`else
	wire [13:0] x_num = {3'd0, hc} * 14'd3;
	wire [13:0] y_num = {3'd0, py} * 14'd3;
`endif
	wire [10:0] src_x_raw = x_num[13:2];
	wire [10:0] src_y_raw = y_num[13:2];
	wire [10:0] src_x_f = (src_x_raw > SRC_X_LAST) ? SRC_X_LAST : src_x_raw;
	wire [10:0] src_y_f = (src_y_raw > SRC_Y_LAST) ? SRC_Y_LAST : src_y_raw;
	wire [10:0] src_x_c_u = src_x_f + 11'd1;
	wire [10:0] src_y_c_u = src_y_f + 11'd1;
	wire [10:0] src_x_c = (src_x_c_u > SRC_X_LAST) ? SRC_X_LAST : src_x_c_u;
	wire [10:0] src_y_c = (src_y_c_u > SRC_Y_LAST) ? SRC_Y_LAST : src_y_c_u;

`ifdef PRESENT_SCALE_4_3_FAULT_PHASE_OBO
	wire [1:0] ph_x = hc[1:0] + 2'd1;
	wire [1:0] ph_y = py[1:0] + 2'd1;
`else
	wire [1:0] ph_x = hc[1:0];
	wire [1:0] ph_y = py[1:0];
`endif

	wire [7:0] wx0_w = (ph_x == 2'd0) ? 8'd255 :
	                   (ph_x == 2'd1) ? 8'd192 :
	                   (ph_x == 2'd2) ? 8'd128 : 8'd64;
	wire [7:0] wx1_w = (ph_x == 2'd0) ? 8'd0 :
	                   (ph_x == 2'd1) ? 8'd64 :
	                   (ph_x == 2'd2) ? 8'd128 : 8'd192;
	wire [7:0] wy0_w = (ph_y == 2'd0) ? 8'd255 :
	                   (ph_y == 2'd1) ? 8'd192 :
	                   (ph_y == 2'd2) ? 8'd128 : 8'd64;
	wire [7:0] wy1_w = (ph_y == 2'd0) ? 8'd0 :
	                   (ph_y == 2'd1) ? 8'd64 :
	                   (ph_y == 2'd2) ? 8'd128 : 8'd192;

`ifdef PRESENT_SCALE_4_3_VTAPS4
	reg signed [7:0] v_t0, v_t1, v_t2, v_t3;
	always @(*) begin
		case (ph_y)
			2'd0: begin v_t0 = 0;  v_t1 = 127; v_t2 = 0;   v_t3 = 0;  end
			2'd1: begin v_t0 = -6; v_t1 = 105; v_t2 = 36;  v_t3 = -7; end
			2'd2: begin v_t0 = -8; v_t1 = 72;  v_t2 = 72;  v_t3 = -8; end
			default: begin v_t0 = -7; v_t1 = 36; v_t2 = 105; v_t3 = -6; end
		endcase
	end
	wire [10:0] y_m1_u = (src_y_f == 11'd0) ? 11'd0 : (src_y_f - 11'd1);
	wire [10:0] y_p2_u = src_y_c + 11'd1;
	wire [10:0] y_p2_c = (y_p2_u > SRC_Y_LAST) ? SRC_Y_LAST : y_p2_u;
`endif

	always @(posedge clk) begin
		if (reset) begin
			store_x <= 0; store_y <= 0; store_x1 <= 0; store_y1 <= 0;
			phase_x <= 0; phase_y <= 0;
			wx0 <= 255; wx1 <= 0; wy0 <= 255; wy1 <= 0;
			de_r <= 0;
`ifdef PRESENT_SCALE_4_3_VTAPS4
			vt0 <= 0; vt1 <= 127; vt2 <= 0; vt3 <= 0;
			store_y_m1 <= 0; store_y_p2 <= 0;
`endif
		end else if (ce_pix) begin
			de_r <= in_content;
			store_x <= src_x_f; store_y <= src_y_f;
			store_x1 <= src_x_c; store_y1 <= src_y_c;
			phase_x <= ph_x; phase_y <= ph_y;
			wx0 <= wx0_w; wx1 <= wx1_w; wy0 <= wy0_w; wy1 <= wy1_w;
`ifdef PRESENT_SCALE_4_3_VTAPS4
			vt0 <= v_t0; vt1 <= v_t1; vt2 <= v_t2; vt3 <= v_t3;
			store_y_m1 <= y_m1_u; store_y_p2 <= y_p2_c;
`endif
		end
	end

	wire ratio_pin = RATIO_W_OK & RATIO_H_OK;
	// synthesis translate_off
	initial if (!ratio_pin) $error("present_scale_4_3: SRC/DST not exact 4/3");
	// synthesis translate_on
endmodule

`default_nettype wire
