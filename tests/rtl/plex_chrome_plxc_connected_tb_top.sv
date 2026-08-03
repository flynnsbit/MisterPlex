// Connected loader → CDC FIFO → host_if (rd-duck registered-valid hole).
// DEPTH=8 shallow FIFO; freeze rd_clk to hit full mid-transaction.
`timescale 1ns / 1ps
`default_nettype none

module plex_chrome_plxc_connected_tb (
	input  wire        clk_sys,
	input  wire        clk_hdmi,
	input  wire        reset,
	input  wire        mem_we_host,
	input  wire [28:0] mem_addr_host,
	input  wire [63:0] mem_wdata_host,
	input  wire        freeze_rd, // 1 = hold hdmi domain (no dequeue)
	output wire        host_we_sys,
	output wire        cdc_full,
	output wire        cdc_empty,
	output wire [15:0] last_seq,
	output wire [31:0] cnt_loads,
	output wire        busy,
	output wire        list_we,
	output wire [7:0]  list_waddr,
	output wire [63:0] list_wdata,
	output wire        cfg_enable,
	output wire [7:0]  cfg_count,
	output wire [15:0] cfg_seq,
	// observe every CDC rd beat
	output wire        rd_we,
	output wire [7:0]  rd_addr,
	output wire [63:0] rd_data
);

	reg [63:0] mem [0:511];
	integer i;
	initial begin
		for (i = 0; i < 512; i = i + 1)
			mem[i] = 64'd0;
	end

	always @(posedge clk_sys) begin
		if (mem_we_host && mem_addr_host < 29'd512)
			mem[mem_addr_host[8:0]] <= mem_wdata_host;
	end

	wire        m_req, m_we;
	wire [28:0] m_addr;
	wire [63:0] m_wdata;
	reg         m_gnt, m_rd_valid;
	reg  [63:0] m_rdata;
	reg         pend_rd;
	reg  [28:0] pend_addr;

	always @(posedge clk_sys) begin
		if (reset) begin
			m_gnt <= 1'b0;
			m_rd_valid <= 1'b0;
			m_rdata <= 64'd0;
			pend_rd <= 1'b0;
			pend_addr <= 29'd0;
		end else begin
			m_gnt <= 1'b0;
			m_rd_valid <= 1'b0;
			if (pend_rd) begin
				m_rd_valid <= 1'b1;
				m_rdata <= (pend_addr < 29'd512) ? mem[pend_addr[8:0]] : 64'd0;
				pend_rd <= 1'b0;
			end else if (m_req) begin
				m_gnt <= 1'b1;
				pend_addr <= m_addr;
				if (m_we) begin
					if (m_addr < 29'd512)
						mem[m_addr[8:0]] <= m_wdata;
				end else
					pend_rd <= 1'b1;
			end
		end
	end

	wire [7:0]  host_addr;
	wire [63:0] host_wdata;
	wire        host_ready = ~cdc_full;

	plex_chrome_ddr_loader #(
		.ENABLE(1'b1),
		.MAX_CMDS(112),
		.DOORBELL_PHYS(32'h0),
		.POLL_DIV(16'd4)
	) u_loader (
		.clk(clk_sys),
		.reset(reset),
		.m_req(m_req),
		.m_we(m_we),
		.m_addr(m_addr),
		.m_wdata(m_wdata),
		.m_gnt(m_gnt),
		.m_rd_valid(m_rd_valid),
		.m_rdata(m_rdata),
		.host_ready(host_ready),
		.host_we(host_we_sys),
		.host_addr(host_addr),
		.host_wdata(host_wdata),
		.chrome_hw(1'b1),
		.mon_w(12'd1280),
		.mon_h(12'd720),
		.mon_scale(4'd3),
		.last_seq(last_seq),
		.busy(busy),
		.cnt_loads(cnt_loads),
		.cnt_plxo_wr(),
		.cnt_bad_magic(),
		.cnt_torn()
	);

	// Gated rd clock: freeze stops dequeue (fill-to-full).
	wire rd_clk_eff = freeze_rd ? 1'b0 : clk_hdmi;

	plex_chrome_plxc_cdc #(.DEPTH(8)) u_cdc (
		.wr_clk(clk_sys),
		.wr_rst(reset),
		.wr_en(host_we_sys),
		.wr_addr(host_addr),
		.wr_data(host_wdata),
		.wr_full(cdc_full),
		.wr_almost_full(),
		.rd_clk(rd_clk_eff),
		.rd_rst(reset),
		.rd_we(rd_we),
		.rd_addr(rd_addr),
		.rd_data(rd_data),
		.rd_empty(cdc_empty)
	);

	plex_chrome_host_if #(.MAX_CMDS(112)) u_hif (
		.clk(rd_clk_eff),
		.reset(reset),
		.host_we(rd_we),
		.host_addr(rd_addr),
		.host_wdata(rd_data),
		.has_frame(1'b1),
		.osd_idle_mode(2'd0),
		.idle_phase_in(16'd0),
		.vsync_in(1'b0),
		.fab_phase_en(1'b0),
		.list_we(list_we),
		.list_waddr(list_waddr),
		.list_wdata(list_wdata),
		.cfg_enable(cfg_enable),
		.cfg_seq(cfg_seq),
		.cfg_cmd_count(cfg_count),
		.idle_en(),
		.idle_mode(),
		.idle_phase(),
		.chrome_hw_sticky(),
		.plxo_seq()
	);
endmodule
`default_nettype wire
