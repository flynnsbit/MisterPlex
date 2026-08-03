`default_nettype none
module present_nn_linebuf_scaler_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire [10:0] in_w,
	input  wire [10:0] in_h,
	input  wire [10:0] out_w,
	input  wire [10:0] out_h,
	input  wire        start,
	output wire        busy,
	output wire        done,
	input  wire        in_valid,
	output wire        in_ready,
	input  wire [7:0]  in_pixel,
	output wire        out_valid,
	input  wire        out_ready,
	output wire [7:0]  out_pixel,
	output wire [10:0] out_x,
	output wire [10:0] out_y
);
	present_nn_linebuf_scaler #(
		.IN_W_MAX(1280),
		.OUT_W_MAX(1280),
		.IN_H_MAX(720),
		.OUT_H_MAX(720)
	) dut (
		.clk(clk),
		.reset(reset),
		.in_w(in_w),
		.in_h(in_h),
		.out_w(out_w),
		.out_h(out_h),
		.start(start),
		.busy(busy),
		.done(done),
		.in_valid(in_valid),
		.in_ready(in_ready),
		.in_pixel(in_pixel),
		.out_valid(out_valid),
		.out_ready(out_ready),
		.out_pixel(out_pixel),
		.out_x(out_x),
		.out_y(out_y)
	);
endmodule
`default_nettype wire
