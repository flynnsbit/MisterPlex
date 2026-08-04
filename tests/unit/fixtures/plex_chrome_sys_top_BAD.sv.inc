// FROZEN c74c6863 anti-pattern — list_we tied off, BOOT_DEMO only.
// Host gate MUST fail this. Do not ship.
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
		.cfg_enable(1'b1),
		.cfg_seq(16'd1),
		.cfg_cmd_count(8'd1),
		.list_we(1'b0),
		.list_waddr(8'd0),
		.list_wdata(64'd0),
		.chrome_hw(plex_chrome_hw),
		.mon_width(plex_chrome_mon_w),
		.mon_height(plex_chrome_mon_h),
		.mon_body_scale(plex_chrome_mon_scale)
	);
