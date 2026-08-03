// Thin top for present_content_window NN mapper (fabric scaler V1).
// Product geometry: FRAME 640x480, H_DE=529, V_STORE=480.
`default_nettype none

module present_content_window_tb #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int H_DE_I = 529,
	parameter int V_STORE_I = 480
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        ce_pix,
	input  wire [9:0]  hc,
	input  wire [9:0]  py,
	input  wire        in_content,
	input  wire        win_enable,
	input  wire [9:0]  content_w,
	input  wire [9:0]  content_h,
	input  wire [9:0]  content_x0,
	input  wire [9:0]  content_y0,
	output wire [9:0]  store_x,
	output wire [8:0]  store_y,
	output wire        de_r,
	output wire        past_last_row
);
	// FRAME_W=640 → clog2=10; FRAME_H=480 → clog2=9
	wire [$clog2(FRAME_W)-1:0] sx;
	wire [$clog2(FRAME_H)-1:0] sy;

	present_content_window #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.H_DE_I(H_DE_I),
		.V_STORE_I(V_STORE_I)
	) dut (
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
		.store_x(sx),
		.store_y(sy),
		.de_r(de_r),
		.past_last_row(past_last_row)
	);

	assign store_x = 10'(sx);
	assign store_y = 9'(sy);
endmodule

`default_nettype wire
