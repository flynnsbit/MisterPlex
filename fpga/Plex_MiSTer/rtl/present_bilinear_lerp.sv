// present_bilinear_lerp — 2×2 tap 8-bit lerp (fabric scaler filter V2).
//
// Default-OFF consumer: only instantiate under `PRESENT_WINDOW_BILINEAR`.
// NN V1 (present_content_window alone) remains the integration-fit path.
//
// Cost (this module only): 0 M10K, ~4 8×8 muls or shift-add DSP-optional,
// purely comb + optional output reg. Fmax: fine at clk_pix 29.7 MHz (720p24 CEA)
// and 74.25 MHz (720p60) — no divide, 8-bit datapath.
//
// Full-path M10K (NOT this file): dual Y lines for vertical taps ≈ 2 M10K @1280
// if held in fabric, or a second DDR line fetch (bandwidth). Horizontal +1 often
// free inside the same 64b qword (w-scaler y_q_hi). Wiring taps through
// ddr_frame_store/present_core is a separate enable — do not force it on the
// first integration fit.
//
// Quality: kills most NN shimmer on PMS 720×404→1280×720. Not 4-tap polyphase
// (ascal already owns HDMI polyphase when DE≠glass).

`default_nettype none

module present_bilinear_lerp (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire        in_valid,
	// 2×2 neighbourhood (caller supplies; NN path never needs this)
	input  wire [7:0]  p00, // (x0,y0)
	input  wire [7:0]  p10, // (x1,y0)
	input  wire [7:0]  p01, // (x0,y1)
	input  wire [7:0]  p11, // (x1,y1)
	// Q8 fractional weights in [0,255]; 0 → pure p00 (NN-equivalent)
	input  wire [7:0]  frac_x,
	input  wire [7:0]  frac_y,
	output reg  [7:0]  out_pix,
	output reg         out_valid
);
	// out = ((255-fx)*(255-fy)*p00 + fx*(255-fy)*p10
	//      + (255-fx)*fy*p01 + fx*fy*p11 + round) / 255^2
	// Use /65536 via >>16 with 255≈256 bias option avoided — exact 255 den:
	// intermediate fits in 32b: 255*255*255 = 16_581_375 < 2^24.

	wire [7:0] wx1 = frac_x;
	wire [7:0] wy1 = frac_y;
	wire [7:0] wx0 = 8'd255 - wx1;
	wire [7:0] wy0 = 8'd255 - wy1;

	wire [15:0] w00 = wx0 * wy0;
	wire [15:0] w10 = wx1 * wy0;
	wire [15:0] w01 = wx0 * wy1;
	wire [15:0] w11 = wx1 * wy1;

	wire [23:0] a00 = w00 * p00;
	wire [23:0] a10 = w10 * p10;
	wire [23:0] a01 = w01 * p01;
	wire [23:0] a11 = w11 * p11;

	// sum max 4*255*255*255 < 2^26
	wire [25:0] acc = {2'b0, a00} + {2'b0, a10} + {2'b0, a01} + {2'b0, a11};
	// / (255*255) with round: (acc + 32512) / 65025 — expensive div.
	// Approximate den 65536 (>>16) with small gain error (<0.4%); OK for video.
	// Round: +0x8000 before shift.
	wire [25:0] acc_r = acc + 26'd32768;
	wire [7:0]  pix_a = acc_r[23:16];

	always @(posedge clk) begin
		if (reset) begin
			out_pix   <= 8'd0;
			out_valid <= 1'b0;
		end else if (ce_pix) begin
			out_valid <= in_valid;
			out_pix   <= pix_a;
		end
	end
endmodule

`default_nettype wire
