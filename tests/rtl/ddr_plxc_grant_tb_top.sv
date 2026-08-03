// ddr_plxc_grant_tb_top — prove PLXC chrome gets m_gnt + beats, video not
// starved (product), and starve_video=1 red twin produces underrun.
//
// Clocks collapsed: clk drives arb + consumers (CDC FIFOs still present).
`timescale 1ns / 1ps
`default_nettype none

module ddr_plxc_grant_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        starve_mode,     // 1 = red twin
	input  wire        run_enable,      // start traffic
	// host preload into fake DDR (byte offset via qword addr)
	input  wire        host_we,
	input  wire [28:0] host_addr,
	input  wire [63:0] host_wdata,
	// observability
	output wire        plxc_m_gnt,
	output wire        plxc_m_req,
	output wire        plxc_m_rd_valid,
	output wire [31:0] plxc_cnt_loads,
	output wire [31:0] plxc_cnt_plxo,
	output wire [31:0] bridge_cnt_gnt,
	output wire [31:0] bridge_cnt_rd,
	output wire [31:0] bridge_cnt_we,
	output wire        grant_m3_live,
	output wire [31:0] arb_cnt_m0,
	output wire [31:0] arb_cnt_m1,
	output wire [31:0] arb_cnt_m3,
	output wire [31:0] video_rd_ok,
	output wire [31:0] video_underrun,
	output wire [31:0] video_max_lat,
	output wire [15:0] plxc_last_seq,
	output wire        plxc_busy
);

	// ---- Fake DDR: 4K qwords, CAS=2 ----
	reg [63:0] mem [0:4095];
	integer mi;
	initial begin
		for (mi = 0; mi < 4096; mi = mi + 1)
			mem[mi] = 64'd0;
	end

	always @(posedge clk) begin
		if (host_we)
			mem[host_addr[11:0]] <= host_wdata;
	end

	reg        ddr_busy;
	reg  [7:0] ddr_burst_left;
	reg [28:0] ddr_addr_r;
	reg        ddr_is_rd;
	reg  [1:0] cas;
	reg [63:0] ddr_dout;
	reg        ddr_dout_ready;
	wire [7:0]  ddram_burstcnt;
	wire [28:0] ddram_addr;
	wire        ddram_rd, ddram_we;
	wire [63:0] ddram_din;
	wire [7:0]  ddram_be;

	always @(posedge clk) begin
		if (reset) begin
			ddr_busy <= 1'b0;
			ddr_burst_left <= 8'd0;
			ddr_addr_r <= 29'd0;
			ddr_is_rd <= 1'b0;
			cas <= 2'd0;
			ddr_dout <= 64'd0;
			ddr_dout_ready <= 1'b0;
		end else begin
			ddr_dout_ready <= 1'b0;
			if (!ddr_busy) begin
				if (ddram_rd || ddram_we) begin
					ddr_busy <= 1'b1;
					ddr_burst_left <= ddram_burstcnt;
					ddr_addr_r <= ddram_addr;
					ddr_is_rd <= ddram_rd;
					cas <= 2'd2;
					if (ddram_we)
						mem[ddram_addr[11:0]] <= ddram_din;
				end
			end else if (cas != 2'd0) begin
				cas <= cas - 2'd1;
			end else if (ddr_is_rd) begin
				ddr_dout <= mem[ddr_addr_r[11:0]];
				ddr_dout_ready <= 1'b1;
				if (ddr_burst_left <= 8'd1) begin
					ddr_busy <= 1'b0;
					ddr_burst_left <= 8'd0;
				end else begin
					ddr_burst_left <= ddr_burst_left - 8'd1;
					ddr_addr_r <= ddr_addr_r + 29'd1;
					cas <= 2'd1;
				end
			end else begin
				// WE complete single/multi
				if (ddr_burst_left <= 8'd1) begin
					ddr_busy <= 1'b0;
					ddr_burst_left <= 8'd0;
				end else begin
					ddr_burst_left <= ddr_burst_left - 8'd1;
					ddr_addr_r <= ddr_addr_r + 29'd1;
					mem[ddr_addr_r[11:0] + 12'd1] <= ddram_din;
				end
			end
		end
	end

	// ---- Video master (m0): periodic single-beat RDs with deadline ----
	// Product path: need response within LAT_LIMIT cycles or underrun++.
	localparam int LINE_PERIOD = 40;   // issue rate
	localparam int LAT_LIMIT   = 24;   // max acceptable grant→data latency
	localparam int BURST_BEATS = 4;    // consecutive RDs per line

	reg        m0_rd, m0_we;
	reg  [7:0] m0_burstcnt, m0_be;
	reg [28:0] m0_addr;
	reg [63:0] m0_din;
	wire       m0_busy;
	wire [63:0] m0_dout;
	wire       m0_dout_ready;

	reg [15:0] line_ctr;
	reg  [3:0] beats_left;
	reg        wait_rsp;
	reg        issuing;
	reg [15:0] lat_ctr;
	reg [31:0] rd_ok_r, underrun_r, max_lat_r;
	reg [28:0] vid_addr;

	assign video_rd_ok    = rd_ok_r;
	assign video_underrun = underrun_r;
	assign video_max_lat  = max_lat_r;

	always @(posedge clk) begin
		if (reset) begin
			m0_rd <= 1'b0;
			m0_we <= 1'b0;
			m0_burstcnt <= 8'd1;
			m0_be <= 8'hFF;
			m0_addr <= 29'd0;
			m0_din <= 64'd0;
			line_ctr <= 16'd0;
			beats_left <= 4'd0;
			wait_rsp <= 1'b0;
			issuing <= 1'b0;
			lat_ctr <= 16'd0;
			rd_ok_r <= 32'd0;
			underrun_r <= 32'd0;
			max_lat_r <= 32'd0;
			vid_addr <= 29'd256; // away from mailbox
		end else begin
			m0_rd <= 1'b0;
			m0_we <= 1'b0;
			if (!run_enable) begin
				line_ctr <= 16'd0;
				beats_left <= 4'd0;
				wait_rsp <= 1'b0;
				issuing <= 1'b0;
			end else begin
				if (wait_rsp) begin
					lat_ctr <= lat_ctr + 16'd1;
					if (m0_dout_ready) begin
						rd_ok_r <= rd_ok_r + 32'd1;
						if ({16'd0, lat_ctr} > max_lat_r)
							max_lat_r <= {16'd0, lat_ctr};
						wait_rsp <= 1'b0;
						issuing <= 1'b0;
						if (beats_left != 4'd0)
							beats_left <= beats_left - 4'd1;
					end else if (lat_ctr >= LAT_LIMIT[15:0]) begin
						// Response starvation (accepted cmd, data late)
						underrun_r <= underrun_r + 32'd1;
						wait_rsp <= 1'b0;
						issuing <= 1'b0;
						beats_left <= 4'd0;
					end
				end else if (issuing) begin
					// Hold RD until arbiter accepts (!busy while rd high)
					m0_rd   <= 1'b1;
					m0_addr <= vid_addr;
					lat_ctr <= lat_ctr + 16'd1;
					if (!m0_busy) begin
						wait_rsp <= 1'b1;
						issuing  <= 1'b0;
						lat_ctr  <= 16'd0;
						vid_addr <= vid_addr + 29'd1;
					end else if (lat_ctr >= LAT_LIMIT[15:0]) begin
						// Issue starvation (never granted) — red-twin path
						underrun_r <= underrun_r + 32'd1;
						issuing <= 1'b0;
						beats_left <= 4'd0;
					end
				end else if (beats_left != 4'd0) begin
					issuing <= 1'b1;
					m0_rd   <= 1'b1;
					m0_addr <= vid_addr;
					lat_ctr <= 16'd0;
				end else begin
					line_ctr <= line_ctr + 16'd1;
					if (line_ctr >= LINE_PERIOD[15:0]) begin
						line_ctr <= 16'd0;
						beats_left <= BURST_BEATS[3:0];
					end
				end
			end
		end
	end

	// ---- m1 idle (no bitstream traffic in this TB) ----
	wire m1_want = 1'b0;
	wire m1_busy;
	wire m1_rd = 1'b0, m1_we = 1'b0;
	wire [7:0] m1_burstcnt = 8'd1, m1_be = 8'hFF;
	wire [28:0] m1_addr = 29'd0;
	wire [63:0] m1_din = 64'd0, m1_dout;
	wire m1_dout_ready;

	// ---- PLXC chrome loader + bridge (m3) ----
	// DOORBELL 0 so PLXC at qword 0x130/8 = 0x26, list at 0x140/8
	wire        c_req, c_we;
	wire [28:0] c_addr;
	wire [63:0] c_wdata;
	wire        c_gnt, c_rd_valid;
	wire [63:0] c_rdata;

	wire        a_want, a_busy, a_rd, a_we, a_dout_ready;
	wire  [7:0] a_burstcnt, a_be;
	wire [28:0] a_addr;
	wire [63:0] a_din, a_dout;

	// Red twin flood: keep m3 wanting forever with continuous RDs.
	wire        m3_want_mux, m3_rd_mux, m3_we_mux;
	wire  [7:0] m3_burst_mux, m3_be_mux;
	wire [28:0] m3_addr_mux;
	wire [63:0] m3_din_mux;
	wire        m3_busy;
	wire [63:0] m3_dout;
	wire        m3_dout_ready;

	reg        flood_rd;
	reg [28:0] flood_addr;
	always @(posedge clk) begin
		if (reset) begin
			flood_rd <= 1'b0;
			flood_addr <= 29'd8;
		end else begin
			flood_rd <= 1'b0;
			if (starve_mode && run_enable && !m3_busy) begin
				flood_rd <= 1'b1;
				flood_addr <= flood_addr + 29'd1;
			end
		end
	end

	assign m3_want_mux  = starve_mode ? 1'b1 : a_want;
	assign m3_rd_mux    = starve_mode ? flood_rd : a_rd;
	assign m3_we_mux    = starve_mode ? 1'b0 : a_we;
	assign m3_burst_mux = starve_mode ? 8'd1 : a_burstcnt;
	assign m3_be_mux    = starve_mode ? 8'hFF : a_be;
	assign m3_addr_mux  = starve_mode ? flood_addr : a_addr;
	assign m3_din_mux   = starve_mode ? 64'd0 : a_din;

	assign a_busy       = m3_busy;
	assign a_dout       = m3_dout;
	assign a_dout_ready = m3_dout_ready;

	plex_chrome_ddr_loader #(
		.ENABLE(1'b1),
		.MAX_CMDS(8),
		.DOORBELL_PHYS(32'h0000_0000),
		.PLXC_OFF(32'h130),
		.PLXO_OFF(32'h138),
		.PLXL_OFF(32'h140),
		.POLL_DIV(16'd8)
	) u_chrome (
		.clk(clk),
		.reset(reset),
		.m_req(c_req),
		.m_we(c_we),
		.m_addr(c_addr),
		.m_wdata(c_wdata),
		.m_gnt(c_gnt),
		.m_rd_valid(c_rd_valid),
		.m_rdata(c_rdata),
		.host_we(),
		.host_addr(),
		.host_wdata(),
		.chrome_hw(1'b1),
		.mon_w(12'd1280),
		.mon_h(12'd720),
		.mon_scale(4'd3),
		.last_seq(plxc_last_seq),
		.busy(plxc_busy),
		.cnt_loads(plxc_cnt_loads),
		.cnt_plxo_wr(plxc_cnt_plxo),
		.cnt_bad_magic()
	);

	wire m3_accept;
	ddr_plxc_master_bridge u_bridge (
		.clk(clk),
		.reset(reset),
		.c_req(c_req),
		.c_we(c_we),
		.c_addr(c_addr),
		.c_wdata(c_wdata),
		.c_gnt(c_gnt),
		.c_rd_valid(c_rd_valid),
		.c_rdata(c_rdata),
		.a_want(a_want),
		.a_busy(a_busy),
		.a_accept(m3_accept),
		.a_burstcnt(a_burstcnt),
		.a_addr(a_addr),
		.a_dout(a_dout),
		.a_dout_ready(a_dout_ready),
		.a_rd(a_rd),
		.a_din(a_din),
		.a_be(a_be),
		.a_we(a_we),
		.cnt_gnt(bridge_cnt_gnt),
		.cnt_rd_beats(bridge_cnt_rd),
		.cnt_we_beats(bridge_cnt_we)
	);

	ddr_bus_arbiter_plxc #(
		.STARVE_VIDEO(1'b0)
	) u_arb (
		.clk(clk),
		.clk_m1(clk),
		.clk_m3(clk),
		.reset(reset),
		.starve_video(starve_mode),
		.m1_want(m1_want),
		.m3_want(m3_want_mux),
		.m0_busy(m0_busy),
		.m0_burstcnt(m0_burstcnt),
		.m0_addr(m0_addr),
		.m0_dout(m0_dout),
		.m0_dout_ready(m0_dout_ready),
		.m0_rd(m0_rd),
		.m0_din(m0_din),
		.m0_be(m0_be),
		.m0_we(m0_we),
		.m1_busy(m1_busy),
		.m1_burstcnt(m1_burstcnt),
		.m1_addr(m1_addr),
		.m1_dout(m1_dout),
		.m1_dout_ready(m1_dout_ready),
		.m1_rd(m1_rd),
		.m1_din(m1_din),
		.m1_be(m1_be),
		.m1_we(m1_we),
		.m1_accept(),
		.m3_busy(m3_busy),
		.m3_burstcnt(m3_burst_mux),
		.m3_addr(m3_addr_mux),
		.m3_dout(m3_dout),
		.m3_dout_ready(m3_dout_ready),
		.m3_rd(m3_rd_mux),
		.m3_din(m3_din_mux),
		.m3_be(m3_be_mux),
		.m3_we(m3_we_mux),
		.m3_accept(m3_accept),
		.grant_m3_live(grant_m3_live),
		.cnt_grant_m0(arb_cnt_m0),
		.cnt_grant_m1(arb_cnt_m1),
		.cnt_grant_m3(arb_cnt_m3),
		.DDRAM_BUSY(ddr_busy),
		.DDRAM_BURSTCNT(ddram_burstcnt),
		.DDRAM_ADDR(ddram_addr),
		.DDRAM_DOUT(ddr_dout),
		.DDRAM_DOUT_READY(ddr_dout_ready),
		.DDRAM_RD(ddram_rd),
		.DDRAM_DIN(ddram_din),
		.DDRAM_BE(ddram_be),
		.DDRAM_WE(ddram_we)
	);

	assign plxc_m_gnt = c_gnt;
	assign plxc_m_req = c_req;
	assign plxc_m_rd_valid = c_rd_valid;

endmodule

`default_nettype wire
