// plex_present_geom_mux — product content/window/geom hierarchy (B8)
//
// Single source used by Plex.sv and the top-level B8 hierarchy TB.
// Priority: PRESENT_BEAM_960 (960×540) > FABRIC_NATIVE_720P_GEOM (1280) >
//           PLXG live > O[4] 640/320 ladder.
// Storage under beam is 960×540 (U@518400), NOT DE canvas 1280.

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
	wire [10:0] content_width_base =
		(plxg_live_valid && (plxg_cw != 11'd0)) ? plxg_cw :
		(content_res_640x480 ? 11'd640 : 11'd320);
	wire [10:0] content_height_base =
		(plxg_live_valid && (plxg_ch != 11'd0)) ? plxg_ch :
		(content_res_640x480 ? 11'd480 : 11'd240);

`ifdef PRESENT_BEAM_960
	wire force_native_960 = 1'b1;
`else
	wire force_native_960 = 1'b0;
`endif
`ifdef FABRIC_NATIVE_720P_GEOM
	wire force_native_720p = 1'b1;
`else
	wire force_native_720p = 1'b0;
`endif

	assign present_win_enable  = force_native_960 | force_native_720p | plxg_win_en;
	assign present_geom_enable = force_native_960 | force_native_720p | plxg_geom_en;
	assign content_width  = force_native_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : content_width_base);
	assign content_height = force_native_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : content_height_base);
	assign present_content_x0 = (force_native_960 | force_native_720p) ? 11'd0 : plxg_cx0;
	assign present_content_y0 = (force_native_960 | force_native_720p) ? 11'd0 : plxg_cy0;
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
	assign present_geom_present_x = (force_native_960 | force_native_720p) ? 11'd0 : plxg_px;
	assign present_geom_present_y = (force_native_960 | force_native_720p) ? 11'd0 : plxg_py;
	assign present_geom_crop_left = (force_native_960 | force_native_720p) ? 11'd0 : plxg_cl;
	assign present_geom_crop_top  = (force_native_960 | force_native_720p) ? 11'd0 : plxg_ct;
endmodule

`default_nettype wire
