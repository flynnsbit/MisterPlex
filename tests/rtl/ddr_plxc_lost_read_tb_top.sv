// ddr_plxc_lost_read_tb_top — product-store launch-edge vs grant_m3 race
//
// Models ddr_frame_store S_LINE_ISSUE/WAIT:
//   - one-shot RD pulse (clear whenever !m0_busy)
//   - ISSUE only when !busy && !rd
//   - WAIT completes only on dout_ready; never re-pulses RD while waiting
//   - hang if WAIT exceeds HANG_LIM with no data
//
// m3 keeps sticky want and issues bridge-like RD only when !m3_busy, so idle
// owner selection repeatedly races grant_m3 against the store launch edge.
// Product arbiter must complete fills with fill_hang==0.
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
	output wire [31:0] arb_m3,
	output wire [31:0] m3_beats,
	output wire        grant_m3_live,
	output wire [3:0]  m0_state_live,
	output wire [31:0] collision_edges
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

	// ---- m0: product store pulse model (single-beat launches) ----
	localparam [3:0] ST_IDLE  = 4'd0;
	localparam [3:0] ST_ISSUE = 4'd1;
	localparam [3:0] ST_WAIT  = 4'd2;
	localparam int   HANG_LIM = 48;
	localparam int   BEATS_PER_LINE = 4;
	localparam int   LINE_GAP = 3;

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
	reg [31:0] coll_r;
	reg        prev_grant_m3;
	wire       grant_m3_w;

	assign fill_ok   = ok_r;
	assign fill_hang = hang_r;
	assign m0_state_live = st;
	assign collision_edges = coll_r;
	assign grant_m3_live = grant_m3_w;

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
			coll_r <= 32'd0;
			prev_grant_m3 <= 1'b0;
		end else begin
			// Product store: drop cmd strobes whenever !busy (one-shot pulse).
			if (!m0_busy) begin
				m0_rd <= 1'b0;
				m0_we <= 1'b0;
			end

			// Count edges where grant_m3 rises while m0 is launching/waiting.
			prev_grant_m3 <= grant_m3_w;
			if (grant_m3_w && !prev_grant_m3 && (st == ST_ISSUE || st == ST_WAIT || m0_rd))
				coll_r <= coll_r + 32'd1;

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
						// Match store S_LINE_ISSUE gate.
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
							// Lost-read signature: WAIT with no routed response.
							hang_r <= hang_r + 32'd1;
							st <= ST_IDLE;
							gap_ctr <= LINE_GAP[15:0];
							hang_ctr <= 16'd0;
							m0_rd <= 1'b0;
						end
					end
					default: st <= ST_IDLE;
				endcase
			end
		end
	end

	// ---- m1 idle ----
	wire m1_want = 1'b0;
	wire m1_busy;
	wire m1_rd = 1'b0, m1_we = 1'b0;
	wire [7:0] m1_burstcnt = 8'd1, m1_be = 8'hFF;
	wire [28:0] m1_addr = 29'd0;
	wire [63:0] m1_din = 64'd0, m1_dout;
	wire m1_dout_ready;

	// ---- m3: sticky want + bridge-like RD after !busy ----
	wire m3_busy;
	wire [63:0] m3_dout;
	wire m3_dout_ready;
	reg        m3_want;
	reg        m3_rd, m3_we;
	reg  [7:0] m3_burstcnt, m3_be;
	reg [28:0] m3_addr;
	reg [63:0] m3_din;
	reg [31:0] m3_beats_r;
	reg        m3_wait;

	assign m3_beats = m3_beats_r;

	always @(posedge clk) begin
		if (reset) begin
			m3_want <= 1'b0;
			m3_rd <= 1'b0;
			m3_we <= 1'b0;
			m3_burstcnt <= 8'd1;
			m3_be <= 8'hFF;
			m3_addr <= 29'd8;
			m3_din <= 64'd0;
			m3_beats_r <= 32'd0;
			m3_wait <= 1'b0;
		end else begin
			m3_rd <= 1'b0;
			m3_we <= 1'b0;
			m3_want <= run_enable;
			if (!run_enable) begin
				m3_wait <= 1'b0;
			end else if (m3_wait) begin
				if (m3_dout_ready) begin
					m3_beats_r <= m3_beats_r + 32'd1;
					m3_wait <= 1'b0;
				end
			end else if (!m3_busy) begin
				m3_rd <= 1'b1;
				m3_addr <= m3_addr + 29'd1;
				m3_wait <= 1'b1;
			end
		end
	end

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
		.m3_busy(m3_busy),
		.m3_burstcnt(m3_burstcnt),
		.m3_addr(m3_addr),
		.m3_dout(m3_dout),
		.m3_dout_ready(m3_dout_ready),
		.m3_rd(m3_rd),
		.m3_din(m3_din),
		.m3_be(m3_be),
		.m3_we(m3_we),
		.grant_m3_live(grant_m3_w),
		.cnt_grant_m0(arb_m0),
		.cnt_grant_m1(),
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
