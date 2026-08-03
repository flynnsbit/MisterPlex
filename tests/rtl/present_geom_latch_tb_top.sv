`default_nettype none
module present_geom_latch_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_en,
	input  wire [2:0]  wr_idx,
	input  wire [63:0] wr_data,
	input  wire        commit,
	output wire        win_enable,
	output wire        geom_enable,
	output wire [10:0] content_w,
	output wire [10:0] content_h,
	output wire [10:0] coded_w,
	output wire [10:0] coded_h,
	output wire [11:0] y_stride,
	output wire [10:0] chroma_stride,
	output wire        live_valid,
	output wire [15:0] live_seq
);
	wire [10:0] content_x0, content_y0, h_de, v_de;
	wire [10:0] display_w, display_h, present_x, present_y, crop_left, crop_top;
	present_geom_latch dut (
		.clk(clk), .reset(reset),
		.wr_en(wr_en), .wr_idx(wr_idx), .wr_data(wr_data), .commit(commit),
		.win_enable(win_enable), .geom_enable(geom_enable),
		.content_w(content_w), .content_h(content_h),
		.content_x0(content_x0), .content_y0(content_y0),
		.h_de(h_de), .v_de(v_de),
		.coded_w(coded_w), .coded_h(coded_h),
		.y_stride(y_stride), .chroma_stride(chroma_stride),
		.display_w(display_w), .display_h(display_h),
		.present_x(present_x), .present_y(present_y),
		.crop_left(crop_left), .crop_top(crop_top),
		.live_valid(live_valid), .live_seq(live_seq)
	);
endmodule
`default_nettype wire
