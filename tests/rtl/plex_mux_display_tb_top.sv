// plex_mux_display_tb — PLXG q3 display_w/h must survive mux (624/618 oracle).
// Product: content-bearing coded=624 display=618 crop_left=3 → out_dw=618.
// FAULT_MUX_DISPLAY_EQ_CODED: out_dw=624 (REPRO contract drop).
`timescale 1ns / 1ps
`default_nettype none

module plex_mux_display_tb (
	input  wire        plxg_live,
	input  wire        plxg_geom,
	input  wire [10:0] plxg_cw,
	input  wire [10:0] plxg_ch,
	input  wire [10:0] plxg_coded_w,
	input  wire [10:0] plxg_coded_h,
	input  wire [11:0] plxg_y_stride,
	input  wire [10:0] plxg_c_stride,
	input  wire [10:0] plxg_dw,
	input  wire [10:0] plxg_dh,
	input  wire [10:0] plxg_cl,
	input  wire [10:0] plxg_ct,
	output wire        obs_geom_en,
	output wire [10:0] obs_coded_w,
	output wire [10:0] obs_display_w,
	output wire [10:0] obs_display_h,
	output wire [10:0] obs_crop_l,
	output wire [10:0] obs_crop_t,
	// crop+display vs coded (store E2 predicate shape)
	output wire        obs_window_ok
);
	wire win_en;
	wire [10:0] cw, ch, cx0, cy0, hde, vde;
	wire [10:0] gch, gcs, gdh, gpx, gpy;
	wire [11:0] gys;

	plex_present_geom_mux u_mux (
		.content_res_640x480(1'b1),
		.plxg_live_valid(plxg_live),
		.plxg_win_en(1'b1),
		.plxg_geom_en(plxg_geom),
		.plxg_cw(plxg_cw),
		.plxg_ch(plxg_ch),
		.plxg_cx0(11'd0),
		.plxg_cy0(11'd0),
		.plxg_hde(11'd640),
		.plxg_vde(11'd480),
		.plxg_coded_w(plxg_coded_w),
		.plxg_coded_h(plxg_coded_h),
		.plxg_y_stride(plxg_y_stride),
		.plxg_c_stride(plxg_c_stride),
		.plxg_dw(plxg_dw),
		.plxg_dh(plxg_dh),
		.plxg_px(11'd0),
		.plxg_py(11'd0),
		.plxg_cl(plxg_cl),
		.plxg_ct(plxg_ct),
		.present_win_enable(win_en),
		.present_geom_enable(obs_geom_en),
		.content_width(cw),
		.content_height(ch),
		.present_content_x0(cx0),
		.present_content_y0(cy0),
		.present_win_h_de(hde),
		.present_win_v_de(vde),
		.present_geom_coded_w(obs_coded_w),
		.present_geom_coded_h(gch),
		.present_geom_y_stride(gys),
		.present_geom_chroma_stride(gcs),
		.present_geom_display_w(obs_display_w),
		.present_geom_display_h(obs_display_h),
		.present_geom_present_x(gpx),
		.present_geom_present_y(gpy),
		.present_geom_crop_left(obs_crop_l),
		.present_geom_crop_top(obs_crop_t)
	);

	// Same shape as ddr_frame_store rt_crop_disp bounds (E2).
	wire [11:0] sum_w = {1'b0, obs_crop_l} + {1'b0, obs_display_w};
	wire [11:0] sum_h = {1'b0, obs_crop_t} + {1'b0, obs_display_h};
	assign obs_window_ok =
		(sum_w <= {1'b0, obs_coded_w}) &&
		(sum_h <= {1'b0, gch});
endmodule

`default_nettype wire
