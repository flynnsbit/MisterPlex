// plex_present_geom_mux — product content/window/geom hierarchy (B8 + B13)
//
// COLLISION #5: force_native_960 is MAX-TIER FALLBACK when PLXG is idle only.
// rd-duck explicit-disable: live_valid=1,cw=ch=0,geom=0 is mode exit — must NOT
// re-enable 960 store geometry. Beam DE fallback is separate from store geom.
// Storage under beam fallback is 960×540 (U@518400), NOT DE canvas 1280.

`timescale 1ns / 1ps
`default_nettype none

module plex_present_geom_mux (
	input  wire        content_res_640x480,
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
	// Content-bearing PLXG (B13 runtime DE).
	wire plxg_content = plxg_live_valid && (plxg_cw != 11'd0) && (plxg_ch != 11'd0);
	// Any committed PLXG record — including explicit disable (cw=ch=0, geom=0).
	wire plxg_owned = plxg_live_valid;

	wire [10:0] ladder_w = content_res_640x480 ? 11'd640 : 11'd320;
	wire [10:0] ladder_h = content_res_640x480 ? 11'd480 : 11'd240;

`ifdef PRESENT_BEAM_960
`ifdef FAULT_B8_FORCE_ALWAYS
	wire beam_fallback_960 = 1'b1;
`elsif FAULT_B8_DISABLE_IGNORED
	// RED twin (rd-duck #6): treat content-empty as idle so owned disable
	// re-arms 960 store geom (pre-fix: plxg_live required cw/ch nonzero).
	wire beam_fallback_960 = ~plxg_content;
`else
	// Idle only — owned disable does not count as idle.
	wire beam_fallback_960 = ~plxg_owned;
`endif
`else
	wire beam_fallback_960 = 1'b0;
`endif
`ifdef FABRIC_NATIVE_720P_GEOM
	wire force_native_720p = 1'b1;
`else
	wire force_native_720p = 1'b0;
`endif

	// Under owned disable: keep HDMI beam at max-tier DE (960×540) so the glass
	// does not collapse, but store geom_enable stays 0 (legacy bank pitch).
	wire disable_beam_de = plxg_owned && !plxg_content && !plxg_geom_en;
`ifdef PRESENT_BEAM_960
	wire beam_de_960 = beam_fallback_960 | disable_beam_de;
`else
	wire beam_de_960 = 1'b0;
`endif

`ifdef FAULT_B8_FORCE_ALWAYS
	// RED twin COLLISION #5: force-first pins 960 over live PLXG content.
	assign present_win_enable  = 1'b1 | force_native_720p | plxg_win_en;
	assign present_geom_enable = 1'b1 | force_native_720p | plxg_geom_en;
	assign content_width  = 11'd960;
	assign content_height = 11'd540;
	assign present_geom_coded_w = 11'd960;
	assign present_geom_coded_h = 11'd540;
	assign present_geom_y_stride = 12'd960;
	assign present_geom_chroma_stride = 11'd480;
	assign present_win_h_de = 11'd960;
	assign present_win_v_de = 11'd540;
`elsif FAULT_B8_DISABLE_IGNORED
	// RED twin: content-empty treated as idle → re-arms 960 store geom.
	assign present_win_enable  = beam_fallback_960 | force_native_720p | plxg_win_en;
	assign present_geom_enable = beam_fallback_960 | force_native_720p | plxg_geom_en;
	assign content_width  = beam_fallback_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : (plxg_content ? plxg_cw : ladder_w));
	assign content_height = beam_fallback_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : (plxg_content ? plxg_ch : ladder_h));
	assign present_geom_coded_w = beam_fallback_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : plxg_coded_w);
	assign present_geom_coded_h = beam_fallback_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : plxg_coded_h);
	assign present_geom_y_stride = beam_fallback_960 ? 12'd960 :
		(force_native_720p ? 12'd1280 : plxg_y_stride);
	assign present_geom_chroma_stride = beam_fallback_960 ? 11'd480 :
		(force_native_720p ? 11'd640 : plxg_c_stride);
	assign present_win_h_de = beam_fallback_960 ? 11'd960 :
		(force_native_720p ? 11'd1280 : plxg_hde);
	assign present_win_v_de = beam_fallback_960 ? 11'd540 :
		(force_native_720p ? 11'd720 : plxg_vde);
`else
	assign present_win_enable  = beam_fallback_960 | force_native_720p | plxg_win_en | disable_beam_de;
	// Store geom: NEVER arm from beam fallback while PLXG owns the latch.
	assign present_geom_enable = (beam_fallback_960 & ~plxg_owned) | force_native_720p | plxg_geom_en;
	assign content_width  = plxg_content ? plxg_cw :
		(beam_de_960 ? 11'd960 : (force_native_720p ? 11'd1280 : ladder_w));
	assign content_height = plxg_content ? plxg_ch :
		(beam_de_960 ? 11'd540 : (force_native_720p ? 11'd720 : ladder_h));
	assign present_win_h_de = plxg_content ? plxg_hde :
		(beam_de_960 ? 11'd960 : (force_native_720p ? 11'd1280 : plxg_hde));
	assign present_win_v_de = plxg_content ? plxg_vde :
		(beam_de_960 ? 11'd540 : (force_native_720p ? 11'd720 : plxg_vde));
	// Store coded/stride only when content-bearing or idle force; disable → 0.
	assign present_geom_coded_w = plxg_content ? plxg_coded_w :
		((beam_fallback_960 & ~plxg_owned) ? 11'd960 :
		(force_native_720p ? 11'd1280 : plxg_coded_w));
	assign present_geom_coded_h = plxg_content ? plxg_coded_h :
		((beam_fallback_960 & ~plxg_owned) ? 11'd540 :
		(force_native_720p ? 11'd720 : plxg_coded_h));
	assign present_geom_y_stride = plxg_content ? plxg_y_stride :
		((beam_fallback_960 & ~plxg_owned) ? 12'd960 :
		(force_native_720p ? 12'd1280 : plxg_y_stride));
	assign present_geom_chroma_stride = plxg_content ? plxg_c_stride :
		((beam_fallback_960 & ~plxg_owned) ? 11'd480 :
		(force_native_720p ? 11'd640 : plxg_c_stride));
`endif

	assign present_content_x0 = plxg_content ? plxg_cx0 : 11'd0;
	assign present_content_y0 = plxg_content ? plxg_cy0 : 11'd0;
	assign present_geom_display_w = present_geom_coded_w;
	assign present_geom_display_h = present_geom_coded_h;
	assign present_geom_present_x = plxg_content ? plxg_px : 11'd0;
	assign present_geom_present_y = plxg_content ? plxg_py : 11'd0;
	assign present_geom_crop_left = plxg_content ? plxg_cl : 11'd0;
	assign present_geom_crop_top  = plxg_content ? plxg_ct : 11'd0;
endmodule

`default_nettype wire
