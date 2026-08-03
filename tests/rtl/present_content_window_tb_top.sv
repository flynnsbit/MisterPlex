// Thin top for present_content_window NN mapper (720p-native STORE 1280×720).
`default_nettype none

module present_content_window_tb #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int STORE_W = 1280,
	parameter int STORE_H = 720,
	parameter int H_DE_DEFAULT = 529,
	parameter int V_DE_DEFAULT = 480
)(
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
	output wire [10:0] store_x,
	output wire [10:0] store_y,
	output wire        de_r,
	output wire        past_last_row
);
	wire [$clog2(STORE_W)-1:0] sx;
	wire [$clog2(STORE_H)-1:0] sy;

	present_content_window #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.STORE_W(STORE_W),
		.STORE_H(STORE_H),
		.H_DE_DEFAULT(H_DE_DEFAULT),
		.V_DE_DEFAULT(V_DE_DEFAULT)
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
		.h_de(h_de),
		.v_de(v_de),
		.store_x(sx),
		.store_y(sy),
		.de_r(de_r),
		.past_last_row(past_last_row)
	);

	assign store_x = 11'(sx);
	assign store_y = 11'(sy);
endmodule

`default_nettype wire
