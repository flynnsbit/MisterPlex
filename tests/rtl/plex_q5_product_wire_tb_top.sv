// Product-shaped q5 wire path: latch → plxg_* → video_ar + fps_sel
// FAULT_DROP_LATCH_Q5: omit latch→consumer wires (undriven consumer) — red twin.
`timescale 1ns / 1ps
`default_nettype none

module plex_q5_product_wire_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        wr_en,
	input  wire [2:0]  wr_idx,
	input  wire [63:0] wr_data,
	input  wire        commit,
	input  wire        frame_boundary,
	input  wire [1:0]  ar_menu,
	output wire [12:0] VIDEO_ARX,
	output wire [12:0] VIDEO_ARY,
	output wire [7:0]  content_fps_eff,
	output wire        plxg_dar_valid_obs,
	output wire        plxg_fps_valid_obs,
	output wire [11:0] plxg_dar_x_obs,
	output wire [7:0]  plxg_content_fps_obs
);
	wire        plxg_dar_valid;
	wire [11:0] plxg_dar_x, plxg_dar_y;
	wire        plxg_fps_valid;
	wire [7:0]  plxg_content_fps;

	// unused geom sinks
	wire win_en, geom_en, live_valid, pending_valid, promote_pulse;
	wire [10:0] cw, ch, cx0, cy0, coded_w, coded_h, c_stride, dw, dh, px, py, cl, ct;
	wire [11:0] h_de, v_de, y_stride;
	wire [15:0] live_seq;
	wire [13:0] live_epoch;

	present_geom_latch u_plxg_latch (
		.clk(clk),
		.reset(reset),
		.wr_en(wr_en),
		.wr_idx(wr_idx),
		.wr_data(wr_data),
		.commit(commit),
		.frame_boundary(frame_boundary),
		.win_enable(win_en),
		.geom_enable(geom_en),
		.content_w(cw),
		.content_h(ch),
		.content_x0(cx0),
		.content_y0(cy0),
		.h_de(h_de),
		.v_de(v_de),
		.coded_w(coded_w),
		.coded_h(coded_h),
		.y_stride(y_stride),
		.chroma_stride(c_stride),
		.display_w(dw),
		.display_h(dh),
		.present_x(px),
		.present_y(py),
		.crop_left(cl),
		.crop_top(ct),
`ifndef FAULT_DROP_LATCH_Q5
		.dar_valid(plxg_dar_valid),
		.dar_x(plxg_dar_x),
		.dar_y(plxg_dar_y),
		.fps_valid(plxg_fps_valid),
		.content_fps(plxg_content_fps),
`else
		// RED: latch q5 ports left unconnected — consumers undriven/X
		.dar_valid(),
		.dar_x(),
		.dar_y(),
		.fps_valid(),
		.content_fps(),
`endif
		.live_valid(live_valid),
		.live_seq(live_seq),
		.live_epoch(live_epoch),
		.pending_valid(pending_valid),
		.promote_pulse(promote_pulse)
	);

`ifdef FAULT_DROP_LATCH_Q5
	// Consumers still exist but nets never driven by latch (product miss class).
	assign plxg_dar_valid = 1'bx;
	assign plxg_dar_x = 12'bx;
	assign plxg_dar_y = 12'bx;
	assign plxg_fps_valid = 1'bx;
	assign plxg_content_fps = 8'bx;
`endif

	plex_video_ar u_plex_video_ar (
		.ar_menu(ar_menu),
		.host_dar_valid(plxg_dar_valid),
		.host_dar_x(plxg_dar_x),
		.host_dar_y(plxg_dar_y),
		.VIDEO_ARX(VIDEO_ARX),
		.VIDEO_ARY(VIDEO_ARY)
	);

	plex_content_fps_sel u_content_fps_sel (
		.fps_valid(plxg_fps_valid),
		.content_fps_q5(plxg_content_fps),
		.content_fps_eff(content_fps_eff)
	);

	assign plxg_dar_valid_obs = plxg_dar_valid;
	assign plxg_fps_valid_obs = plxg_fps_valid;
	assign plxg_dar_x_obs = plxg_dar_x;
	assign plxg_content_fps_obs = plxg_content_fps;
endmodule
`default_nettype wire
