// present_bilinear_lerp — 2×2 Q8 lerp for PRESENT_WINDOW_BILINEAR (default OFF).
// Pure combinational; 0 M10K. Tap fetch / line hold is the caller's problem.
// Not auto-wired into present_core (fit risk).

`default_nettype none

module present_bilinear_lerp (
	input  wire [7:0] p00,  // (x0,y0)
	input  wire [7:0] p10,  // (x1,y0)
	input  wire [7:0] p01,  // (x0,y1)
	input  wire [7:0] p11,  // (x1,y1)
	input  wire [7:0] frac_x,
	input  wire [7:0] frac_y,
	output wire [7:0] out_pix
);
	// one_m_f = 256 - f  (9-bit so f=0 → 256)
	wire [8:0] one_m_fx = 9'd256 - {1'b0, frac_x};
	wire [8:0] one_m_fy = 9'd256 - {1'b0, frac_y};

	// top = (p00*(256-fx) + p10*fx) >> 8
	wire [16:0] top_v = p00 * one_m_fx + p10 * {1'b0, frac_x};
	wire [16:0] bot_v = p01 * one_m_fx + p11 * {1'b0, frac_x};
	wire [7:0] top8 = top_v[15:8];
	wire [7:0] bot8 = bot_v[15:8];
	wire [16:0] mix = top8 * one_m_fy + bot8 * {1'b0, frac_y};
	assign out_pix = mix[15:8];
endmodule

`default_nettype wire
