// Bilinear filter V2 TB top — window fracs + lerp (PRESENT_WINDOW_BILINEAR).
`default_nettype none

module present_bilinear_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [10:0] hc,
	input  wire [10:0] py,
	input  wire        in_content,
	input  wire        win_enable,
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,
	input  wire [10:0] content_x0,
	input  wire [10:0] content_y0,
	input  wire [10:0] h_de,
	input  wire [10:0] v_de,
	// Synthetic 2×2 taps (TB drives known pattern)
	input  wire [7:0]  p00,
	input  wire [7:0]  p10,
	input  wire [7:0]  p01,
	input  wire [7:0]  p11,
	output wire [10:0] store_x,
	output wire [10:0] store_y,
	output wire [10:0] store_x1,
	output wire [10:0] store_y1,
	output wire [7:0]  frac_x,
	output wire [7:0]  frac_y,
	output wire [7:0]  out_pix,
	output wire        out_valid,
	output wire        de_r
);
	localparam int STORE_W = 1280;
	localparam int STORE_H = 720;

	wire [$clog2(STORE_W)-1:0] sx, sx1;
	wire [$clog2(STORE_H)-1:0] sy, sy1;

	present_content_window #(
		.FRAME_W(640),
		.FRAME_H(480),
		.STORE_W(STORE_W),
		.STORE_H(STORE_H),
		.H_DE_DEFAULT(529),
		.V_DE_DEFAULT(480)
	) win (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.hc(hc),
		.py(py),
		.in_content(in_content),
		.win_enable(win_enable),
		.content_w(content_w),
		.content_h(content_h),
		.content_x0(content_x0),
		.content_y0(content_y0),
		.h_de(h_de),
		.v_de(v_de),
		.store_x(sx),
		.store_y(sy),
		.de_r(de_r),
		.past_last_row(),
		.store_x1(sx1),
		.store_y1(sy1),
		.frac_x(frac_x),
		.frac_y(frac_y)
	);

	present_bilinear_lerp lerp (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix),
		.in_valid(in_content),
		.p00(p00),
		.p10(p10),
		.p01(p01),
		.p11(p11),
		.frac_x(frac_x),
		.frac_y(frac_y),
		.out_pix(out_pix),
		.out_valid(out_valid)
	);

	assign store_x  = 11'(sx);
	assign store_y  = 11'(sy);
	assign store_x1 = 11'(sx1);
	assign store_y1 = 11'(sy1);
endmodule

`default_nettype wire
