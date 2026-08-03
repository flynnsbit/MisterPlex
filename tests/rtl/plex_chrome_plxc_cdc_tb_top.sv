// Hierarchy TB: clk_sys(20M) → CDC → clk_hdmi(74.25M) → host_if
// Proves >=2 list words + ctrl all arrive. Red twin: edge-detect path.
`timescale 1ns / 1ps
`default_nettype none

module plex_chrome_plxc_cdc_tb (
	input  wire        clk_sys,
	input  wire        clk_hdmi,
	input  wire        reset,
	// drive sys-side beats (loader style: consecutive we=1 OK)
	input  wire        sys_we,
	input  wire [7:0]  sys_addr,
	input  wire [63:0] sys_data,
	// product CDC → host_if observe
	output wire        prod_host_we,
	output wire [7:0]  prod_host_addr,
	output wire [63:0] prod_host_data,
	output wire        prod_list_we,
	output wire [7:0]  prod_list_waddr,
	output wire [63:0] prod_list_wdata,
	output wire        prod_cfg_enable,
	output wire [7:0]  prod_cfg_count,
	output wire [15:0] prod_cfg_seq,
	output wire        prod_wr_full,
	// shallow CDC (DEPTH=8) for stopped-rd fill-to-full + resume
	input  wire        sh_we,
	input  wire [7:0]  sh_addr,
	input  wire [63:0] sh_data,
	output wire        sh_host_we,
	output wire [7:0]  sh_host_addr,
	output wire [63:0] sh_host_data,
	output wire        sh_wr_full,
	output wire        sh_rd_empty,
	// fault edge CDC observe
	output wire        fault_host_we,
	output wire [7:0]  fault_host_addr,
	output wire [63:0] fault_host_data
);
	wire full, afull, empty;
	wire f_full, f_afull, f_empty;
	wire sh_afull;

	plex_chrome_plxc_cdc #(.DEPTH(128)) u_prod (
		.wr_clk(clk_sys),
		.wr_rst(reset),
		.wr_en(sys_we),
		.wr_addr(sys_addr),
		.wr_data(sys_data),
		.wr_full(full),
		.wr_almost_full(afull),
		.rd_clk(clk_hdmi),
		.rd_rst(reset),
		.rd_we(prod_host_we),
		.rd_addr(prod_host_addr),
		.rd_data(prod_host_data),
		.rd_empty(empty)
	);
	assign prod_wr_full = full;

	// DEPTH=8: fill while rd clock stopped, then resume — conservation under stall.
	plex_chrome_plxc_cdc #(.DEPTH(8)) u_shallow (
		.wr_clk(clk_sys),
		.wr_rst(reset),
		.wr_en(sh_we), // TB must hold sh_we=0 when sh_wr_full (loader host_ready)
		.wr_addr(sh_addr),
		.wr_data(sh_data),
		.wr_full(sh_wr_full),
		.wr_almost_full(sh_afull),
		.rd_clk(clk_hdmi),
		.rd_rst(reset),
		.rd_we(sh_host_we),
		.rd_addr(sh_host_addr),
		.rd_data(sh_host_data),
		.rd_empty(sh_rd_empty)
	);

	plex_chrome_plxc_cdc_edge_fault u_fault (
		.wr_clk(clk_sys),
		.wr_rst(reset),
		.wr_en(sys_we),
		.wr_addr(sys_addr),
		.wr_data(sys_data),
		.wr_full(f_full),
		.wr_almost_full(f_afull),
		.rd_clk(clk_hdmi),
		.rd_rst(reset),
		.rd_we(fault_host_we),
		.rd_addr(fault_host_addr),
		.rd_data(fault_host_data),
		.rd_empty(f_empty)
	);

	// sink host_if on product path
	plex_chrome_host_if #(.MAX_CMDS(112)) u_hif (
		.clk(clk_hdmi),
		.reset(reset),
		.host_we(prod_host_we),
		.host_addr(prod_host_addr),
		.host_wdata(prod_host_data),
		.has_frame(1'b1),
		.osd_idle_mode(2'd0),
		.idle_phase_in(16'd0),
		.vsync_in(1'b0),
		.fab_phase_en(1'b0),
		.list_we(prod_list_we),
		.list_waddr(prod_list_waddr),
		.list_wdata(prod_list_wdata),
		.cfg_enable(prod_cfg_enable),
		.cfg_seq(prod_cfg_seq),
		.cfg_cmd_count(prod_cfg_count),
		.idle_en(),
		.idle_mode(),
		.idle_phase(),
		.chrome_hw_sticky(),
		.plxo_seq()
	);
endmodule
`default_nettype wire
