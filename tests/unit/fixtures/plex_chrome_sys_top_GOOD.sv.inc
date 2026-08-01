// Required product wiring — list_we is a real net (PLXC/doorbell path), not 1'b0.
// BOOT_DEMO may stay 1 for glass '#' until ARM PLXC lands, but write path must live
// so Quartus cannot prove list RAM is unreachable and elide it.
	wire        plex_chrome_list_we;
	wire [7:0]  plex_chrome_list_waddr;
	wire [63:0] plex_chrome_list_wdata;
	// Driven by HPS/DDR mailbox bridge (or sticky pulse from cfg); never constant 0.
	assign plex_chrome_list_we = plxc_list_we; // external net — must not fold to 1'b0

	plex_chrome #(
		.BOOT_DEMO(1)
	) u_plex_chrome (
		.clk_hdmi(clk_hdmi),
		.reset(reset_req),
		.HDMI_WIDTH(hdmi_width),
		.HDMI_HEIGHT(hdmi_height),
		.din(hdmi_data_mask),
		.hs_in(hdmi_hs_mask),
		.vs_in(hdmi_vs_mask),
		.de_in(hdmi_de_mask),
		.dout(hdmi_data_chrome),
		.hs_out(hdmi_hs_chrome),
		.vs_out(hdmi_vs_chrome),
		.de_out(hdmi_de_chrome),
		.cfg_enable(plxc_cfg_enable),
		.cfg_seq(plxc_cfg_seq),
		.cfg_cmd_count(plxc_cfg_cmd_count),
		.list_we(plex_chrome_list_we),
		.list_waddr(plex_chrome_list_waddr),
		.list_wdata(plex_chrome_list_wdata),
		.chrome_hw(plex_chrome_hw),
		.mon_width(plex_chrome_mon_w),
		.mon_height(plex_chrome_mon_h),
		.mon_body_scale(plex_chrome_mon_scale)
	);
