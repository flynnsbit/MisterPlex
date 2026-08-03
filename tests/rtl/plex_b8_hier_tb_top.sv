// plex_b8_hier_tb_top — product hierarchy B8: mux + present_core under
// PRESENT_BEAM_960 must deliver content/geom 960×540 (not hand-driven ports only).
//
// FAULT_PLXG_TIED: ignore beam force path simulation by zeroing mux inputs and
// compiling WITHOUT PRESENT_BEAM_960 — content falls to 320/640 (must RED).
// FAULT uses separate build; this top always builds with PRESENT_BEAM_960 for
// the good arm. Red twin is a second compile -DFAULT_B8_NO_BEAM.
`timescale 1ns / 1ps
`default_nettype none

module plex_b8_hier_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        content_res_640x480,
	// Optional PLXG live injection (product poller path)
	input  wire        inject_plxg_live,
	input  wire [10:0] inject_cw,
	input  wire [10:0] inject_ch,
	input  wire [10:0] inject_coded_w,
	input  wire [10:0] inject_coded_h,
	input  wire [11:0] inject_y_stride,
	input  wire [10:0] inject_c_stride,
	// Observability (product mux outputs → present_core inputs)
	output wire        obs_win_en,
	output wire        obs_geom_en,
	output wire [10:0] obs_content_w,
	output wire [10:0] obs_content_h,
	output wire [10:0] obs_coded_w,
	output wire [10:0] obs_coded_h,
	output wire [11:0] obs_y_stride,
	output wire [10:0] obs_c_stride,
	output wire [10:0] obs_win_h_de,
	output wire [10:0] obs_win_v_de,
	// present_core beam DE sample
	output wire        obs_ce_pix,
	output wire        obs_hblank,
	output wire        obs_vblank,
	output wire        obs_hsync,
	output wire        obs_vsync,
	// VIDEO_ARX/ARY model matching Plex.sv under beam
	output wire [11:0] obs_video_arx,
	output wire [11:0] obs_video_ary
);

	wire plxg_live = inject_plxg_live;
	wire plxg_win  = inject_plxg_live;
	wire plxg_geom = inject_plxg_live;

	wire        win_en, geom_en;
	wire [10:0] cw, ch, cx0, cy0, hde, vde;
	wire [10:0] gcw, gch, gcs, gdw, gdh, gpx, gpy, gcl, gct;
	wire [11:0] gys;

	plex_present_geom_mux u_mux (
		.content_res_640x480(content_res_640x480),
		.plxg_live_valid(plxg_live),
		.plxg_win_en(plxg_win),
		.plxg_geom_en(plxg_geom),
		.plxg_cw(inject_cw),
		.plxg_ch(inject_ch),
		.plxg_cx0(11'd0),
		.plxg_cy0(11'd0),
		// True-DE tracks content when PLXG live (B13); inject DE == content.
		.plxg_hde(inject_cw),
		.plxg_vde(inject_ch),
		.plxg_coded_w(inject_coded_w),
		.plxg_coded_h(inject_coded_h),
		.plxg_y_stride(inject_y_stride),
		.plxg_c_stride(inject_c_stride),
		.plxg_dw(inject_cw),
		.plxg_dh(inject_ch),
		.plxg_px(11'd0),
		.plxg_py(11'd0),
		.plxg_cl(11'd0),
		.plxg_ct(11'd0),
		.present_win_enable(win_en),
		.present_geom_enable(geom_en),
		.content_width(cw),
		.content_height(ch),
		.present_content_x0(cx0),
		.present_content_y0(cy0),
		.present_win_h_de(hde),
		.present_win_v_de(vde),
		.present_geom_coded_w(gcw),
		.present_geom_coded_h(gch),
		.present_geom_y_stride(gys),
		.present_geom_chroma_stride(gcs),
		.present_geom_display_w(gdw),
		.present_geom_display_h(gdh),
		.present_geom_present_x(gpx),
		.present_geom_present_y(gpy),
		.present_geom_crop_left(gcl),
		.present_geom_crop_top(gct)
	);

	assign obs_win_en = win_en;
	assign obs_geom_en = geom_en;
	assign obs_content_w = cw;
	assign obs_content_h = ch;
	assign obs_coded_w = gcw;
	assign obs_coded_h = gch;
	assign obs_y_stride = gys;
	assign obs_c_stride = gcs;
	assign obs_win_h_de = hde;
	assign obs_win_v_de = vde;

`ifdef PRESENT_BEAM_960
	assign obs_video_arx = 12'd0;
	assign obs_video_ary = 12'd0;
`else
	assign obs_video_arx = 12'd4;
	assign obs_video_ary = 12'd3;
`endif

	// present_core product hierarchy (FRAME 960×540 when beam macro set at elab)
	wire ce_pix, hb, hs, vb, vs;
	wire [7:0] r, g, b;
	wire [15:0] al, ar;
	wire [31:0] di, ci, wr;
	wire adv, hf, ha, au, sp;
	wire [15:0] fu;
	wire [7:0] fss;
	wire fs_rdy;
	wire sdram_sel, sdram_wr, sdram_rd, sdram_refresh;
	wire [26:1] sdram_addr;
	wire [15:0] sdram_din;
	wire [1:0] sdram_bs;

`ifdef DDR_FRAME_STORE
	wire        ddr_clk;
	wire  [7:0] ddr_bc;
	wire [28:0] ddr_addr;
	wire        ddr_rd, ddr_we;
	wire [63:0] ddr_din;
	wire  [7:0] ddr_be;
	wire [15:0] ddr_frames;
	wire        ddr_db_ok;
`endif

	present_core #(
		.FRAME_W(960),
		.FRAME_H(540),
		.FRAME_STRIDE(960),
		.SDRAM_REFRESH_CYCLES(780)
	) u_present (
		.clk(clk),
		.clk_sdram(clk),
		.clk_audio(clk),
		.reset(reset),
		.pal(1'b0),
		.scandouble(1'b0),
		.content_fps(8'd24),
		.display_hz(8'd30),
		.pattern(2'd0),
		.audio_en(1'b0),
		.use_frame_store(1'b0),
		.win_enable(win_en),
		.content_w(cw),
		.content_h(ch),
		.content_x0(cx0),
		.content_y0(cy0),
		.win_h_de(hde),
		.win_v_de(vde),
		.geom_enable(geom_en),
		.geom_coded_w(gcw),
		.geom_coded_h(gch),
		.geom_y_stride(gys),
		.geom_chroma_stride(gcs),
		.geom_display_w(gdw),
		.geom_display_h(gdh),
		.geom_present_x(gpx),
		.geom_present_y(gpy),
		.geom_crop_left(gcl),
		.geom_crop_top(gct),
		.fs_wr_en(1'b0),
		.fs_wr_pixel(16'd0),
		.fs_wr_reset(1'b0),
		.fs_swap(1'b0),
		.fs_wr_ready(fs_rdy),
		.sdram_dout(16'd0),
		.sdram_ready(1'b1),
		.sdram_sel(sdram_sel),
		.sdram_addr(sdram_addr),
		.sdram_din(sdram_din),
		.sdram_wr(sdram_wr),
		.sdram_rd(sdram_rd),
		.sdram_bs(sdram_bs),
		.sdram_refresh(sdram_refresh),
`ifdef DDR_FRAME_STORE
		.ddr_start_req(1'b0),
		.ddr_bank_sel(1'b0),
		.ddr_status_osd(16'd0),
		.ddr_input_cmd_valid(1'b0),
		.ddr_input_cmd(8'd0),
		.ddr_sdram_test_state(4'd0),
		.ddr_sdram_size_code(4'd0),
		.ddr_sdram_error_count(16'd0),
		.clk_ddr(clk),
		.DDRAM_CLK(ddr_clk),
		.DDRAM_BUSY(1'b0),
		.DDRAM_BURSTCNT(ddr_bc),
		.DDRAM_ADDR(ddr_addr),
		.DDRAM_DOUT(64'd0),
		.DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD(ddr_rd),
		.DDRAM_DIN(ddr_din),
		.DDRAM_BE(ddr_be),
		.DDRAM_WE(ddr_we),
		.ddr_frames_done(ddr_frames),
		.ddr_doorbell_ok(ddr_db_ok),
`endif
		.af_wr_en(1'b0),
		.af_wr_data(32'd0),
		.af_wr_flush(1'b0),
		.ce_pix(ce_pix),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.r(r), .g(g), .b(b),
		.audio_l(al), .audio_r(ar),
		.stat_display_index(di),
		.stat_content_index(ci),
		.stat_advance(adv),
		.stat_has_frame(hf),
		.stat_wr_count(wr),
		.stat_has_audio(ha),
		.stat_audio_underrun(au),
		.stat_swap_pending(sp),
		.stat_frame_underruns(fu),
		.stat_frame_sdram_state(fss)
	);

	assign obs_ce_pix = ce_pix;
	assign obs_hblank = hb;
	assign obs_vblank = vb;
	assign obs_hsync = hs;
	assign obs_vsync = vs;

endmodule

`default_nettype wire
