// ddr_plxc_lost_read_tb_top — m0 store launch vs m1/m3 issued-cmd collision
//
// rd-duck: m0_ov must not mask an already-issued lower command; bridge must
// not treat !busy as acceptance. Product: both m0 fills and m1/m3 bridge
// transactions complete after exact same-edge collisions. FAULT_LOST_READ
// restores old hang class.
`timescale 1ns / 1ps
`default_nettype none

module ddr_plxc_lost_read_tb_top #(
	parameter bit FAULT_LOST_READ = 1'b0
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        run_enable,
	output wire [31:0] fill_ok,
	output wire [31:0] fill_hang,
	output wire [31:0] arb_m0,
	output wire [31:0] arb_m1,
	output wire [31:0] arb_m3,
	output wire [31:0] m1_beats,
	output wire [31:0] m3_beats,
	output wire [31:0] m1_gnts,
	output wire [31:0] m3_gnts,
	output wire [31:0] m1_hang,
	output wire [31:0] m3_hang,
	output wire        grant_m3_live,
	output wire [3:0]  m0_state_live,
	output wire [31:0] collision_m0_m3,
	output wire [31:0] collision_m0_m1
);

	// ---- Fake DDR (CAS=2) ----
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
				end
			end else if (cas != 2'd0) begin
				cas <= cas - 2'd1;
			end else if (ddr_is_rd) begin
				ddr_dout <= {32'hA5A5_0000, 3'd0, ddr_addr_r};
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
				if (ddr_burst_left <= 8'd1) begin
					ddr_busy <= 1'b0;
					ddr_burst_left <= 8'd0;
				end else begin
					ddr_burst_left <= ddr_burst_left - 8'd1;
					ddr_addr_r <= ddr_addr_r + 29'd1;
				end
			end
		end
	end

	// ---- m0: product store pulse model ----
	localparam [3:0] ST_IDLE  = 4'd0;
	localparam [3:0] ST_ISSUE = 4'd1;
	localparam [3:0] ST_WAIT  = 4'd2;
	localparam int   HANG_LIM = 512;
	localparam int   BEATS_PER_LINE = 4;
	localparam int   LINE_GAP = 2;

	reg        m0_rd, m0_we;
	reg  [7:0] m0_burstcnt, m0_be;
	reg [28:0] m0_addr;
	reg [63:0] m0_din;
	wire       m0_busy;
	wire [63:0] m0_dout;
	wire       m0_dout_ready;

	reg  [3:0] st;
	reg  [7:0] beats_left;
	reg [15:0] hang_ctr;
	reg [15:0] gap_ctr;
	reg [31:0] ok_r, hang_r;
	reg [28:0] line_base;
	reg [31:0] coll_m3_r, coll_m1_r;
	reg        prev_m3_rd, prev_m1_rd;

	assign fill_ok   = ok_r;
	assign fill_hang = hang_r;
	assign m0_state_live = st;
	assign collision_m0_m3 = coll_m3_r;
	assign collision_m0_m1 = coll_m1_r;

	wire m1_rd_w, m3_rd_w;

	// Phase: 0 = m0+m3 (m1 quiet), 1 = m0+m1 (m3 quiet), 2 = both sparse.
	// Prevents m1 sticky-want from starving m3 for the whole run.
	reg [1:0] phase;
	reg [15:0] phase_ctr;
	wire en_m1 = run_enable && (phase == 2'd1 || (phase == 2'd2 && phase_ctr[2]));
	wire en_m3 = run_enable && (phase == 2'd0 || (phase == 2'd2 && !phase_ctr[2]));
	always @(posedge clk) begin
		if (reset) begin
			phase <= 2'd0;
			phase_ctr <= 16'd0;
		end else if (run_enable) begin
			phase_ctr <= phase_ctr + 16'd1;
			if (phase_ctr == 16'd2499) begin
				phase_ctr <= 16'd0;
				if (phase == 2'd0) phase <= 2'd1;
				else if (phase == 2'd1) phase <= 2'd2;
				else phase <= 2'd0;
			end
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			m0_rd <= 1'b0;
			m0_we <= 1'b0;
			m0_burstcnt <= 8'd1;
			m0_be <= 8'hFF;
			m0_addr <= 29'd0;
			m0_din <= 64'd0;
			st <= ST_IDLE;
			beats_left <= 8'd0;
			hang_ctr <= 16'd0;
			gap_ctr <= 16'd0;
			ok_r <= 32'd0;
			hang_r <= 32'd0;
			line_base <= 29'd64;
			coll_m3_r <= 32'd0;
			coll_m1_r <= 32'd0;
			prev_m3_rd <= 1'b0;
			prev_m1_rd <= 1'b0;
		end else begin
			if (!m0_busy) begin
				m0_rd <= 1'b0;
				m0_we <= 1'b0;
			end

			// Exact same-edge collision count (after NBA both may be 1).
			prev_m3_rd <= m3_rd_w;
			prev_m1_rd <= m1_rd_w;
			if (m0_rd && m3_rd_w)
				coll_m3_r <= coll_m3_r + 32'd1;
			if (m0_rd && m1_rd_w)
				coll_m1_r <= coll_m1_r + 32'd1;

			if (!run_enable) begin
				st <= ST_IDLE;
				hang_ctr <= 16'd0;
				gap_ctr <= 16'd0;
			end else begin
				case (st)
					ST_IDLE: begin
						hang_ctr <= 16'd0;
						if (gap_ctr != 16'd0)
							gap_ctr <= gap_ctr - 16'd1;
						else begin
							beats_left <= BEATS_PER_LINE[7:0];
							m0_addr <= line_base;
							st <= ST_ISSUE;
						end
					end
					ST_ISSUE: begin
						if (!m0_busy && !m0_rd && !m0_we) begin
							m0_rd <= 1'b1;
							m0_burstcnt <= 8'd1;
							m0_addr <= line_base + (BEATS_PER_LINE[7:0] - beats_left);
							st <= ST_WAIT;
							hang_ctr <= 16'd0;
						end else begin
							hang_ctr <= hang_ctr + 16'd1;
							if (hang_ctr >= HANG_LIM[15:0]) begin
								hang_r <= hang_r + 32'd1;
								st <= ST_IDLE;
								gap_ctr <= LINE_GAP[15:0];
								hang_ctr <= 16'd0;
							end
						end
					end
					ST_WAIT: begin
						hang_ctr <= hang_ctr + 16'd1;
						if (m0_dout_ready) begin
							if (beats_left <= 8'd1) begin
								ok_r <= ok_r + 32'd1;
								line_base <= line_base + 29'd16;
								st <= ST_IDLE;
								gap_ctr <= LINE_GAP[15:0];
								hang_ctr <= 16'd0;
								beats_left <= 8'd0;
							end else begin
								beats_left <= beats_left - 8'd1;
								st <= ST_ISSUE;
								hang_ctr <= 16'd0;
							end
						end else if (hang_ctr >= HANG_LIM[15:0]) begin
							hang_r <= hang_r + 32'd1;
							st <= ST_IDLE;
							gap_ctr <= LINE_GAP[15:0];
							hang_ctr <= 16'd0;
							m0_rd <= 1'b0;
						end
					end
					default: st <= ST_IDLE;
				endcase
				// Product only: directed same-edge m0 vs issued lower cmd.
				// FAULT twin omits inject so classic launch-edge fill_hang REPROs
				// (revoke-only grant drop + m0_ov-always without m0 skid accept).
				if (!FAULT_LOST_READ) begin
					if (run_enable && m3_rd_w && grant_m3_w) begin
						m0_rd <= 1'b1;
						m0_burstcnt <= 8'd1;
						m0_addr <= line_base;
						if (st != ST_WAIT) begin
							st <= ST_WAIT;
							hang_ctr <= 16'd0;
							if (beats_left == 8'd0)
								beats_left <= 8'd1;
						end
					end else if (run_enable && m1_rd_w) begin
						m0_rd <= 1'b1;
						m0_burstcnt <= 8'd1;
						m0_addr <= line_base + 29'd8;
						if (st != ST_WAIT) begin
							st <= ST_WAIT;
							hang_ctr <= 16'd0;
							if (beats_left == 8'd0)
								beats_left <= 8'd1;
						end
					end
				end

			end
		end
	end

	// ---- m1 via real bridge (PLXG-like) ----
	wire m1_busy, m1_accept;
	wire [63:0] m1_dout;
	wire m1_dout_ready;
	wire m1_want, m1_rd, m1_we;
	wire [7:0] m1_burstcnt, m1_be;
	wire [28:0] m1_addr;
	wire [63:0] m1_din;
	reg        c1_req, c1_we;
	reg [28:0] c1_addr;
	reg [63:0] c1_wdata;
	wire       c1_gnt, c1_rd_valid;
	wire [63:0] c1_rdata;
	reg [31:0] m1_beats_r, m1_gnts_r, m1_hang_r;
	reg [15:0] m1_wait_ctr;
	reg        m1_inflight;
	reg [7:0]  m1_gap;

	assign m1_beats = m1_beats_r;
	assign m1_gnts  = m1_gnts_r;
	assign m1_hang  = m1_hang_r;
	assign m1_rd_w  = m1_rd;

	ddr_plxc_master_bridge u_m1_br (
		.clk(clk),
		.reset(reset),
		.c_req(c1_req),
		.c_we(c1_we),
		.c_addr(c1_addr),
		.c_wdata(c1_wdata),
		.c_gnt(c1_gnt),
		.c_rd_valid(c1_rd_valid),
		.c_rdata(c1_rdata),
		.a_want(m1_want),
		.a_busy(m1_busy),
		// FAULT: !busy-as-accept REPRO hang under m0_ov mask (rd-duck).
		.a_accept(m1_accept),
		.a_burstcnt(m1_burstcnt),
		.a_addr(m1_addr),
		.a_dout(m1_dout),
		.a_dout_ready(m1_dout_ready),
		.a_rd(m1_rd),
		.a_din(m1_din),
		.a_be(m1_be),
		.a_we(m1_we),
		.cnt_gnt(),
		.cnt_rd_beats(),
		.cnt_we_beats()
	);

	always @(posedge clk) begin
		if (reset) begin
			c1_req <= 1'b0;
			c1_we <= 1'b0;
			c1_addr <= 29'd200;
			c1_wdata <= 64'd0;
			m1_beats_r <= 32'd0;
			m1_gnts_r <= 32'd0;
			m1_hang_r <= 32'd0;
			m1_wait_ctr <= 16'd0;
			m1_inflight <= 1'b0;
			m1_gap <= 8'd0;
		end else begin
			c1_req <= 1'b0;
			if (!en_m1) begin
				m1_inflight <= 1'b0;
				m1_wait_ctr <= 16'd0;
				m1_gap <= 8'd0;
			end else if (m1_inflight) begin
				m1_wait_ctr <= m1_wait_ctr + 16'd1;
				if (c1_gnt)
					m1_gnts_r <= m1_gnts_r + 32'd1;
				if (c1_rd_valid) begin
					m1_beats_r <= m1_beats_r + 32'd1;
					m1_inflight <= 1'b0;
					m1_wait_ctr <= 16'd0;
					m1_gap <= 8'd1;
					c1_addr <= c1_addr + 29'd1;
				end else if (m1_wait_ctr >= HANG_LIM[15:0]) begin
					m1_hang_r <= m1_hang_r + 32'd1;
					m1_inflight <= 1'b0;
					m1_wait_ctr <= 16'd0;
					m1_gap <= 8'd4;
				end
			end else if (m1_gap != 8'd0) begin
				m1_gap <= m1_gap - 8'd1;
			end else begin
				c1_req <= 1'b1;
				c1_we <= 1'b0;
				m1_inflight <= 1'b1;
				m1_wait_ctr <= 16'd0;
			end
		end
	end

	// ---- m3 via real bridge (PLXC) ----
	wire m3_busy, m3_accept;
	wire [63:0] m3_dout;
	wire m3_dout_ready;
	wire m3_want, m3_rd, m3_we;
	wire [7:0] m3_burstcnt, m3_be;
	wire [28:0] m3_addr;
	wire [63:0] m3_din;
	reg        c3_req, c3_we;
	reg [28:0] c3_addr;
	reg [63:0] c3_wdata;
	wire       c3_gnt, c3_rd_valid;
	wire [63:0] c3_rdata;
	reg [31:0] m3_beats_r, m3_gnts_r, m3_hang_r;
	reg [15:0] m3_wait_ctr;
	reg        m3_inflight;
	reg [7:0]  m3_gap;

	assign m3_beats = m3_beats_r;
	assign m3_gnts  = m3_gnts_r;
	assign m3_hang  = m3_hang_r;
	assign m3_rd_w  = m3_rd;

	ddr_plxc_master_bridge u_m3_br (
		.clk(clk),
		.reset(reset),
		.c_req(c3_req),
		.c_we(c3_we),
		.c_addr(c3_addr),
		.c_wdata(c3_wdata),
		.c_gnt(c3_gnt),
		.c_rd_valid(c3_rd_valid),
		.c_rdata(c3_rdata),
		.a_want(m3_want),
		.a_busy(m3_busy),
		.a_accept(m3_accept),
		.a_burstcnt(m3_burstcnt),
		.a_addr(m3_addr),
		.a_dout(m3_dout),
		.a_dout_ready(m3_dout_ready),
		.a_rd(m3_rd),
		.a_din(m3_din),
		.a_be(m3_be),
		.a_we(m3_we),
		.cnt_gnt(),
		.cnt_rd_beats(),
		.cnt_we_beats()
	);

	always @(posedge clk) begin
		if (reset) begin
			c3_req <= 1'b0;
			c3_we <= 1'b0;
			c3_addr <= 29'd8;
			c3_wdata <= 64'd0;
			m3_beats_r <= 32'd0;
			m3_gnts_r <= 32'd0;
			m3_hang_r <= 32'd0;
			m3_wait_ctr <= 16'd0;
			m3_inflight <= 1'b0;
			m3_gap <= 8'd0;
		end else begin
			c3_req <= 1'b0;
			if (!en_m3) begin
				m3_inflight <= 1'b0;
				m3_wait_ctr <= 16'd0;
				m3_gap <= 8'd0;
			end else if (m3_inflight) begin
				m3_wait_ctr <= m3_wait_ctr + 16'd1;
				if (c3_gnt)
					m3_gnts_r <= m3_gnts_r + 32'd1;
				if (c3_rd_valid) begin
					m3_beats_r <= m3_beats_r + 32'd1;
					m3_inflight <= 1'b0;
					m3_wait_ctr <= 16'd0;
					m3_gap <= 8'd0; // sticky pressure on m3
					c3_addr <= c3_addr + 29'd1;
				end else if (m3_wait_ctr >= HANG_LIM[15:0]) begin
					m3_hang_r <= m3_hang_r + 32'd1;
					m3_inflight <= 1'b0;
					m3_wait_ctr <= 16'd0;
					m3_gap <= 8'd2;
				end
			end else if (m3_gap != 8'd0) begin
				m3_gap <= m3_gap - 8'd1;
			end else begin
				c3_req <= 1'b1;
				c3_we <= 1'b0;
				m3_inflight <= 1'b1;
				m3_wait_ctr <= 16'd0;
			end
		end
	end

	wire grant_m3_w;
	assign grant_m3_live = grant_m3_w;

	ddr_bus_arbiter_plxc #(
		.STARVE_VIDEO(1'b0),
		.FAULT_LOST_READ(FAULT_LOST_READ)
	) u_arb (
		.clk(clk),
		.clk_m1(clk),
		.clk_m3(clk),
		.reset(reset),
		.starve_video(1'b0),
		.m1_want(m1_want),
		.m3_want(m3_want),
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
		.m1_accept(m1_accept),
		.m3_busy(m3_busy),
		.m3_burstcnt(m3_burstcnt),
		.m3_addr(m3_addr),
		.m3_dout(m3_dout),
		.m3_dout_ready(m3_dout_ready),
		.m3_rd(m3_rd),
		.m3_din(m3_din),
		.m3_be(m3_be),
		.m3_we(m3_we),
		.m3_accept(m3_accept),
		.grant_m3_live(grant_m3_w),
		.cnt_grant_m0(arb_m0),
		.cnt_grant_m1(arb_m1),
		.cnt_grant_m3(arb_m3),
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

endmodule

`default_nettype wire
