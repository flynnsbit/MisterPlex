// B16 + ABI#2 q5: stage-on-commit, promote-on-frame_boundary, reserved reject.
`timescale 1ns/1ps
`default_nettype none
module present_geom_latch_b16_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_en,
	input  wire [2:0]  wr_idx,
	input  wire [63:0] wr_data,
	input  wire        commit,
	input  wire        frame_boundary,
	output wire        live_valid,
	output wire [15:0] live_seq,
	output wire [13:0] live_epoch,
	output wire        geom_enable,
	output wire [10:0] content_w,
	output wire [10:0] content_h,
	output wire [10:0] coded_w,
	output wire [10:0] coded_h,
	output wire [11:0] y_stride,
	output wire [10:0] chroma_stride,
	output wire [11:0] dar_x,
	output wire [11:0] dar_y,
	output wire [7:0]  content_fps,
	output wire        dar_valid,
	output wire        fps_valid,
	output wire        pending_valid,
	output wire        promote_pulse,
	output wire        q5_reserved_reject,
	output wire        dar_hold_black
);
	present_geom_latch u (
		.clk(clk), .reset(reset),
		.wr_en(wr_en), .wr_idx(wr_idx), .wr_data(wr_data), .commit(commit),
		.frame_boundary(frame_boundary),
		.win_enable(), .geom_enable(geom_enable),
		.content_w(content_w), .content_h(content_h),
		.content_x0(), .content_y0(), .h_de(), .v_de(),
		.coded_w(coded_w), .coded_h(coded_h),
		.y_stride(y_stride), .chroma_stride(chroma_stride),
		.display_w(), .display_h(), .present_x(), .present_y(),
		.crop_left(), .crop_top(),
		.dar_x(dar_x), .dar_y(dar_y), .content_fps(content_fps),
		.dar_valid(dar_valid), .fps_valid(fps_valid),
		.live_valid(live_valid), .live_seq(live_seq), .live_epoch(live_epoch),
		.pending_valid(pending_valid), .promote_pulse(promote_pulse),
		.q5_reserved_reject(q5_reserved_reject),
		.dar_hold_black(dar_hold_black)
	);
endmodule
`default_nettype wire
