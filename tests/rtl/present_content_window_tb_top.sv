// Thin wrapper for Verilator C++ TB of present_content_window.
`default_nettype none
module present_content_window_tb_top (
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
	output wire [10:0] store_x_lane1,
	output wire [9:0]  store_y,
	output wire        de_r,
	output wire        past_last_row
);
	present_content_window #(
		.FRAME_W(640),
		.FRAME_H(480),
		.STORE_W(1280),
		.STORE_H(720),
		.H_DE_DEFAULT(529),
		.V_DE_DEFAULT(480)
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
		.store_x(store_x),
		.store_x_lane1(store_x_lane1),
		.store_y(store_y),
		.de_r(de_r),
		.past_last_row(past_last_row)
	);
endmodule
`default_nettype wire
