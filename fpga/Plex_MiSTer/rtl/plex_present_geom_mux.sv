// plex_present_geom_mux — product content/window/geom hierarchy (B8 + B13)
//
// COLLISION #5 (parent): PRESENT_BEAM_960 must NOT pin content to 960×540 when
// PLXG is live — that killed runtime DE for 96.5% of the library.
// force_native_* is a MAX-TIER FALLBACK when PLXG is idle, never an override.
// Priority: PLXG live > PRESENT_BEAM_960 fallback > FABRIC_NATIVE_720P_GEOM /
//           PRESENT_MULTI_PIXEL idle 720p identity > O[4] 640/320 ladder.
//
// MULTI compose trap (w-scaler): win_enable=0 → present_content_window uses the
// 529-class legacy STORE_X_SCALE. On 1280 glass that is wrong. Idle MULTI must
// force win_enable + 1280×720 identity until PLXG publishes real content.
// M10K=0 ALM≈tens ESTIMATE (combo mux) — fit UNVERIFIED.

`timescale 1ns / 1ps
`default_nettype none

module plex_present_geom_mux (
	input  wire        content_res_640x480,
	// From present_geom_latch / poller (may be zero when idle)
	input  wire        plxg_live_valid,
	input  wire        plxg_win_en,
	input  wire        plxg_geom_en,
	input  wire [10:0] plxg_cw,
	input  wire [10:0] plxg_ch,
	input  wire [10:0] plxg_cx0,
	input  wire [10:0] plxg_cy0,
	input  wire [10:0] plxg_hde,
	input  wire [10:0] plxg_vde,
	input  wire [10:0] plxg_coded_w,
	input  wire [10:0] plxg_coded_h,
	input  wire [11:0] plxg_y_stride,
	input  wire [10:0] plxg_c_stride,
	input  wire [10:0] plxg_dw,
	input  wire [10:0] plxg_dh,
	input  wire [10:0] plxg_px,
	input  wire [10:0] plxg_py,
	input  wire [10:0] plxg_cl,
	input  wire [10:0] plxg_ct,
	// Outputs → present_core
	output wire        present_win_enable,
	output wire        present_geom_enable,
	output wire [10:0] content_width,
	output wire [10:0] content_height,
	output wire [10:0] present_content_x0,
	output wire [10:0] present_content_y0,
	output wire [10:0] present_win_h_de,
	output wire [10:0] present_win_v_de,
	output wire [10:0] present_geom_coded_w,
	output wire [10:0] present_geom_coded_h,
	output wire [11:0] present_geom_y_stride,
	output wire [10:0] present_geom_chroma_stride,
	output wire [10:0] present_geom_display_w,
	output wire [10:0] present_geom_display_h,
	output wire [10:0] present_geom_present_x,
	output wire [10:0] present_geom_present_y,
	output wire [10:0] present_geom_crop_left,
	output wire [10:0] present_geom_crop_top
);
	// Live PLXG: non-zero content (parent B13 / COLLISION #5).
	wire plxg_live = plxg_live_valid && (plxg_cw != 11'd0) && (plxg_ch != 11'd0);

	wire [10:0] content_width_base =
		plxg_live ? plxg_cw :
		(content_res_640x480 ? 11'd640 : 11'd320);
	wire [10:0] content_height_base =
		plxg_live ? plxg_ch :
		(content_res_640x480 ? 11'd480 : 11'd240);

	// PRESENT_BEAM_960: max-tier DEFAULT only when PLXG is not live.
	// FAULT_B8_FORCE_ALWAYS: unconditional force (red twin for COLLISION #5).
`ifdef PRESENT_BEAM_960
`ifdef FAULT_B8_FORCE_ALWAYS
	wire force_native_960 = 1'b1;
`else
	wire force_native_960 = ~plxg_live;
`endif
`else
	wire force_native_960 = 1'b0;
`endif
	// 720p identity fallback when PLXG idle. Same COLLISION #5 rule as 960:
	// never pin 1280×720 over a live PLXG content size.
	// FABRIC_NATIVE_720P_GEOM: explicit QSF (L4 or MULTI fit candidate).
	// PRESENT_MULTI_PIXEL: integ enabled path — same idle default without a
	// second macro (compose must not depend on host PLXG before first frame).
`ifdef FAULT_B8_FORCE_720P_ALWAYS
	wire force_native_720p = 1'b1;
`elsif FABRIC_NATIVE_720P_GEOM
	wire force_native_720p = ~plxg_live;
`elsif PRESENT_MULTI_PIXEL
	wire force_native_720p = ~plxg_live;
`else
	wire force_native_720p = 1'b0;
`endif

	// When PLXG is live, content_* come from latch (content_width_base).
	// Native forces only apply while ~plxg_live (see above).
	assign present_win_enable  = force_native_960 | force_native_720p | plxg_win_en;
	assign present_geom_enable = force_native_960 | force_native_720p | plxg_geom_en;
	assign content_width  = force_native_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : content_width_base);
	assign content_height = force_native_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : content_height_base);
	// Origins: native idle → 0; live PLXG → latch (even if win_en already 1).
	assign present_content_x0 = plxg_live ? plxg_cx0 :
		((force_native_960 | force_native_720p) ? 11'd0 : plxg_cx0);
	assign present_content_y0 = plxg_live ? plxg_cy0 :
		((force_native_960 | force_native_720p) ? 11'd0 : plxg_cy0);
	assign present_win_h_de = force_native_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : plxg_hde);
	assign present_win_v_de = force_native_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : plxg_vde);
	assign present_geom_coded_w = force_native_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : plxg_coded_w);
	assign present_geom_coded_h = force_native_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : plxg_coded_h);
	assign present_geom_y_stride = force_native_960 ? 12'd960 :
		(force_native_720p ? 12'd1280 : plxg_y_stride);
	assign present_geom_chroma_stride = force_native_960 ? 11'd480 :
		(force_native_720p ? 11'd640 : plxg_c_stride);
	assign present_geom_display_w = force_native_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : plxg_dw);
	assign present_geom_display_h = force_native_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : plxg_dh);
	assign present_geom_present_x = plxg_live ? plxg_px :
		((force_native_960 | force_native_720p) ? 11'd0 : plxg_px);
	assign present_geom_present_y = plxg_live ? plxg_py :
		((force_native_960 | force_native_720p) ? 11'd0 : plxg_py);
	assign present_geom_crop_left = plxg_live ? plxg_cl :
		((force_native_960 | force_native_720p) ? 11'd0 : plxg_cl);
	assign present_geom_crop_top  = plxg_live ? plxg_ct :
		((force_native_960 | force_native_720p) ? 11'd0 : plxg_ct);
endmodule

`default_nettype wire
