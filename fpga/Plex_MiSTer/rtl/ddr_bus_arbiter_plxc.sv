// ddr_bus_arbiter_plxc — product 2-master + PLXC (m3) lowest-priority slot
//
// Masters (clk_ddr domain arbitration):
//   m0 — video frame store (scanout). Absolute priority when free to launch.
//   m1 — bitstream/PLXG path (clk_m1 domain, async FIFO responses).
//   m3 — PLXC chrome loader (clk_m3 domain, async FIFO responses).
//
// Priority (product STARVE_VIDEO=0):
//   1) While grant_m1/m3 is held: exclusive lower slot — never m0_ov, never
//      revoke for m0. Complete m*_cmd or release only on !m*_want && !m*_cmd.
//   2) else m0 (live or skid) on free slots
//   3) else m1_want / m3_want grants
//
// Lost-read contracts (rd-duck 44981ab0 residual):
//   A) Store launch-edge: skid m0 one-shot while lower grant held.
//   B) Bridge may sample !busy and arm a_rd before a_accept CDC. Product must
//      NOT drop grant_m3/m1 for m0 while want is live — else WAIT_R hangs with
//      no issued DDR beat and no retry token. a_*_accept is the only advance.
//   FAULT_LOST_READ: m0_ov masks lower mux under grant + revoke-only (loses
//      collided lower request; REPRO hang).
//
// STARVE_VIDEO=1 (red twin only): m3 sticky over m0 — must produce underrun
// in the concurrent-load TB. Never synthesize product with STARVE_VIDEO=1.

`timescale 1ns / 1ps
`default_nettype none

module ddr_bus_arbiter_plxc #(
	parameter bit STARVE_VIDEO = 1'b0,
	// Red twin only: old m0_ov-always + revoke-only preempt (lost-read hangs).
	parameter bit FAULT_LOST_READ = 1'b0
) (
	input  wire        clk,      // DDR bridge clock (90 MHz)
	input  wire        clk_m1,   // m1 consumer clock (20 MHz)
	input  wire        clk_m3,   // m3 PLXC consumer clock (usually clk_sys)
	input  wire        reset,    // synchronous to clk_m1/m3 domain
	input  wire        starve_video,

	input  wire        m1_want,
	input  wire        m3_want,

	output wire        m0_busy,
	input  wire  [7:0] m0_burstcnt,
	input  wire [28:0] m0_addr,
	output wire [63:0] m0_dout,
	output wire        m0_dout_ready,
	input  wire        m0_rd,
	input  wire [63:0] m0_din,
	input  wire  [7:0] m0_be,
	input  wire        m0_we,

	output wire        m1_busy,
	input  wire  [7:0] m1_burstcnt,
	input  wire [28:0] m1_addr,
	output wire [63:0] m1_dout,
	output wire        m1_dout_ready,
	input  wire        m1_rd,
	input  wire [63:0] m1_din,
	input  wire  [7:0] m1_be,
	input  wire        m1_we,
	// Pulse in clk_m1 domain: arbiter accepted m1 cmd onto DDR (not mere !busy).
	output wire        m1_accept,

	output wire        m3_busy,
	input  wire  [7:0] m3_burstcnt,
	input  wire [28:0] m3_addr,
	output wire [63:0] m3_dout,
	output wire        m3_dout_ready,
	input  wire        m3_rd,
	input  wire [63:0] m3_din,
	input  wire  [7:0] m3_be,
	input  wire        m3_we,
	// Pulse in clk_m3 domain: arbiter accepted m3 cmd onto DDR (not mere !busy).
	output wire        m3_accept,

	output wire        grant_m3_live,
	output reg  [31:0] cnt_grant_m0,
	output reg  [31:0] cnt_grant_m1,
	output reg  [31:0] cnt_grant_m3,

	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE
);
	wire starve = STARVE_VIDEO | starve_video;

	reg reset_s1, reset_s2;
	always @(posedge clk or posedge reset) begin
		if (reset) begin
			reset_s1 <= 1'b1;
			reset_s2 <= 1'b1;
		end else begin
			reset_s1 <= 1'b0;
			reset_s2 <= reset_s1;
		end
	end
	wire rst = reset_s2;

	reg m1_want_s1, m1_want_s2;
	reg m3_want_s1, m3_want_s2;
	always @(posedge clk) begin
		if (rst) begin
			m1_want_s1 <= 1'b0;
			m1_want_s2 <= 1'b0;
			m3_want_s1 <= 1'b0;
			m3_want_s2 <= 1'b0;
		end else begin
			m1_want_s1 <= m1_want;
			m1_want_s2 <= m1_want_s1;
			m3_want_s1 <= m3_want;
			m3_want_s2 <= m3_want_s1;
		end
	end

	reg grant_m1, grant_m3;
	reg rsp_owner_m1, rsp_owner_m3;
	reg [8:0] rsp_left;
	reg [63:0] rsp_data_r;
	reg        rsp_valid_r;
	reg        rsp_owner_m1_r, rsp_owner_m3_r;

	// m0 skid: capture one-shot store cmd when a lower master has already issued
	// or the pipe is busy — replay after current grant completes.
	reg        m0_skid_v;
	reg        m0_skid_rd, m0_skid_we;
	reg  [7:0] m0_skid_burst;
	reg [28:0] m0_skid_addr;
	reg [63:0] m0_skid_din;
	reg  [7:0] m0_skid_be;

	wire rsp_active = rsp_left != 9'd0;
	wire rsp_pipe_active = rsp_active | rsp_valid_r;
	wire m0_live_cmd = m0_rd | m0_we;
	wire m1_cmd = m1_rd | m1_we;
	wire m3_cmd = m3_rd | m3_we;

	// Effective m0 command (live preferred, else skid).
	// Prefer live when present
	wire m0_use_live = m0_live_cmd;
	wire m0_use_skid = m0_skid_v & ~m0_live_cmd;
	wire m0_eff_rd_w = m0_use_live ? m0_rd : (m0_use_skid & m0_skid_rd);
	wire m0_eff_we_w = m0_use_live ? m0_we : (m0_use_skid & m0_skid_we);
	wire m0_eff_cmd = m0_eff_rd_w | m0_eff_we_w;
	wire [7:0]  m0_eff_burst = m0_use_live ? m0_burstcnt : m0_skid_burst;
	wire [28:0] m0_eff_addr  = m0_use_live ? m0_addr     : m0_skid_addr;
	wire [63:0] m0_eff_din   = m0_use_live ? m0_din      : m0_skid_din;
	wire [7:0]  m0_eff_be    = m0_use_live ? m0_be       : m0_skid_be;

	// Product: any held lower grant owns the mux until cmd completes or want
	// drops — not merely while m*_cmd is high (bridge arms rd one cycle late).
	wire lower_grant_held = grant_m1 || grant_m3;
	wire lower_cmd_inflight =
		(grant_m1 && m1_cmd) || (grant_m3 && m3_cmd);

	// Product m0_ov only when NO lower grant is held (skid m0 instead).
	// FAULT: m0_ov under grant even without lower cmd — masks mux, loses lower.
	wire m0_ov = !starve && m0_eff_cmd &&
	             (FAULT_LOST_READ ? lower_grant_held : !lower_grant_held);
	wire use_m1 = grant_m1 && !m0_ov;
	wire use_m3 = grant_m3 && !grant_m1 && !m0_ov;

	assign grant_m3_live = grant_m3;

	// m0_busy high while other grants, other rsp, or skid waiting — store holds
	// one-shot RD through the blocked window (clear-on-!busy contract).
	assign m0_busy = DDRAM_BUSY | grant_m1 | grant_m3 | m0_skid_v |
	                 (rsp_active & (rsp_owner_m1 | rsp_owner_m3)) |
	                 (rsp_valid_r & (rsp_owner_m1_r | rsp_owner_m3_r));

	// Comb accept detect (clk domain) — registered + CDC to consumer clocks.
	wire slot_free = !DDRAM_BUSY && !rsp_pipe_active;
	wire m1_accept_comb = slot_free && use_m1 && m1_cmd;
	wire m3_accept_comb = slot_free && use_m3 && m3_cmd;

	// Stretch accept in clk domain so 2FF CDC cannot drop a 1-cycle pulse.
	// Clear when lower cmd drops (bridge finished presenting).
	reg [3:0] m1_acc_stretch, m3_acc_stretch;
	always @(posedge clk) begin
		if (rst) begin
			m1_acc_stretch <= 4'd0;
			m3_acc_stretch <= 4'd0;
		end else begin
			if (m1_accept_comb)
				m1_acc_stretch <= 4'd15;
			else if (m1_acc_stretch != 4'd0 && !m1_cmd)
				m1_acc_stretch <= m1_acc_stretch - 4'd1;
			else if (m1_acc_stretch != 4'd0 && m1_cmd)
				m1_acc_stretch <= m1_acc_stretch; // hold while cmd still presented
			if (m3_accept_comb)
				m3_acc_stretch <= 4'd15;
			else if (m3_acc_stretch != 4'd0 && !m3_cmd)
				m3_acc_stretch <= m3_acc_stretch - 4'd1;
			else if (m3_acc_stretch != 4'd0 && m3_cmd)
				m3_acc_stretch <= m3_acc_stretch;
		end
	end
	wire m1_acc_level = (m1_acc_stretch != 4'd0);
	wire m3_acc_level = (m3_acc_stretch != 4'd0);

	reg m1_acc_s1, m1_acc_s2;
	always @(posedge clk_m1) begin
		if (reset) begin
			m1_acc_s1 <= 1'b0;
			m1_acc_s2 <= 1'b0;
		end else begin
			m1_acc_s1 <= m1_acc_level;
			m1_acc_s2 <= m1_acc_s1;
		end
	end
	assign m1_accept = m1_acc_s2;

	reg m3_acc_s1, m3_acc_s2;
	always @(posedge clk_m3) begin
		if (reset) begin
			m3_acc_s1 <= 1'b0;
			m3_acc_s2 <= 1'b0;
		end else begin
			m3_acc_s1 <= m3_acc_level;
			m3_acc_s2 <= m3_acc_s1;
		end
	end
	assign m3_accept = m3_acc_s2;

	// While product lower cmd is in flight, keep that master able to hold rd/we.
	wire m1_busy_comb = DDRAM_BUSY | !grant_m1 |
	                    (m0_ov && !m1_cmd) |
	                    (rsp_active & !rsp_owner_m1) |
	                    (rsp_valid_r & !rsp_owner_m1_r);
	reg m1_busy_r;
	always @(posedge clk) begin
		if (rst) m1_busy_r <= 1'b1;
		else     m1_busy_r <= m1_busy_comb;
	end
	reg m1_busy_s1, m1_busy_s2;
	always @(posedge clk_m1) begin
		if (reset) begin
			m1_busy_s1 <= 1'b1;
			m1_busy_s2 <= 1'b1;
		end else begin
			m1_busy_s1 <= m1_busy_r;
			m1_busy_s2 <= m1_busy_s1;
		end
	end
	assign m1_busy = m1_busy_s2;

	wire m3_busy_comb = DDRAM_BUSY | !grant_m3 |
	                    (m0_ov && !m3_cmd) |
	                    (rsp_active & !rsp_owner_m3) |
	                    (rsp_valid_r & !rsp_owner_m3_r);
	reg m3_busy_r;
	always @(posedge clk) begin
		if (rst) m3_busy_r <= 1'b1;
		else     m3_busy_r <= m3_busy_comb;
	end
	reg m3_busy_s1, m3_busy_s2;
	always @(posedge clk_m3) begin
		if (reset) begin
			m3_busy_s1 <= 1'b1;
			m3_busy_s2 <= 1'b1;
		end else begin
			m3_busy_s1 <= m3_busy_r;
			m3_busy_s2 <= m3_busy_s1;
		end
	end
	assign m3_busy = m3_busy_s2;

	assign DDRAM_BURSTCNT = use_m1 ? m1_burstcnt :
	                        (use_m3 ? m3_burstcnt : m0_eff_burst);
	assign DDRAM_ADDR     = use_m1 ? m1_addr :
	                        (use_m3 ? m3_addr : m0_eff_addr);
	assign DDRAM_RD       = use_m1 ? m1_rd :
	                        (use_m3 ? m3_rd : m0_eff_rd_w);
	assign DDRAM_DIN      = use_m1 ? m1_din :
	                        (use_m3 ? m3_din : m0_eff_din);
	assign DDRAM_BE       = use_m1 ? m1_be :
	                        (use_m3 ? m3_be : m0_eff_be);
	assign DDRAM_WE       = use_m1 ? m1_we :
	                        (use_m3 ? m3_we : m0_eff_we_w);

	wire rsp_raw_valid = DDRAM_DOUT_READY & rsp_active;

	assign m0_dout = rsp_data_r;
	assign m0_dout_ready = rsp_valid_r & !rsp_owner_m1_r & !rsp_owner_m3_r;

	wire        m1_rsp_fifo_full, m1_rsp_fifo_empty;
	wire [63:0] m1_rsp_fifo_rdata;
	wire        m1_rsp_wr_en = rsp_valid_r & rsp_owner_m1_r;
	async_fifo #(.WIDTH(64), .AW(3)) m1_rsp_fifo (
		.wr_clk(clk), .wr_reset(rst),
		.wr_en(m1_rsp_wr_en), .wr_data(rsp_data_r),
		.wr_full(m1_rsp_fifo_full), .wr_almost_full(),
		.rd_clk(clk_m1), .rd_reset(reset),
		.rd_en(!m1_rsp_fifo_empty), .rd_data(m1_rsp_fifo_rdata),
		.rd_empty(m1_rsp_fifo_empty)
	);
	assign m1_dout       = m1_rsp_fifo_rdata;
	assign m1_dout_ready = !m1_rsp_fifo_empty;

	wire        m3_rsp_fifo_full, m3_rsp_fifo_empty;
	wire [63:0] m3_rsp_fifo_rdata;
	wire        m3_rsp_wr_en = rsp_valid_r & rsp_owner_m3_r;
	async_fifo #(.WIDTH(64), .AW(3)) m3_rsp_fifo (
		.wr_clk(clk), .wr_reset(rst),
		.wr_en(m3_rsp_wr_en), .wr_data(rsp_data_r),
		.wr_full(m3_rsp_fifo_full), .wr_almost_full(),
		.rd_clk(clk_m3), .rd_reset(reset),
		.rd_en(!m3_rsp_fifo_empty), .rd_data(m3_rsp_fifo_rdata),
		.rd_empty(m3_rsp_fifo_empty)
	);
	assign m3_dout       = m3_rsp_fifo_rdata;
	assign m3_dout_ready = !m3_rsp_fifo_empty;

	wire _unused_full = m1_rsp_fifo_full | m3_rsp_fifo_full;

	always @(posedge clk) begin
		if (rst) begin
			grant_m1 <= 1'b0;
			grant_m3 <= 1'b0;
			rsp_owner_m1 <= 1'b0;
			rsp_owner_m3 <= 1'b0;
			rsp_left <= 9'd0;
			rsp_data_r <= 64'd0;
			rsp_valid_r <= 1'b0;
			rsp_owner_m1_r <= 1'b0;
			rsp_owner_m3_r <= 1'b0;
			cnt_grant_m0 <= 32'd0;
			cnt_grant_m1 <= 32'd0;
			cnt_grant_m3 <= 32'd0;
			m0_skid_v <= 1'b0;
			m0_skid_rd <= 1'b0;
			m0_skid_we <= 1'b0;
			m0_skid_burst <= 8'd1;
			m0_skid_addr <= 29'd0;
			m0_skid_din <= 64'd0;
			m0_skid_be <= 8'hFF;
		end else begin
			rsp_valid_r <= rsp_raw_valid;
			if (rsp_raw_valid) begin
				rsp_data_r <= DDRAM_DOUT;
				rsp_owner_m1_r <= rsp_owner_m1;
				rsp_owner_m3_r <= rsp_owner_m3;
			end

			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			// Capture m0 one-shot into skid whenever a lower grant is held or
			// lower rsp is in flight (product). FAULT does not skid (lost m0).
			if (!FAULT_LOST_READ && !starve && m0_live_cmd && !m0_skid_v) begin
				if (lower_grant_held || lower_cmd_inflight ||
				    (rsp_pipe_active && (rsp_owner_m1 || rsp_owner_m3 ||
				                         rsp_owner_m1_r || rsp_owner_m3_r))) begin
					m0_skid_v <= 1'b1;
					m0_skid_rd <= m0_rd;
					m0_skid_we <= m0_we;
					m0_skid_burst <= m0_burstcnt;
					m0_skid_addr <= m0_addr;
					m0_skid_din <= m0_din;
					m0_skid_be <= m0_be;
				end
			end

			if (!DDRAM_BUSY && !rsp_pipe_active) begin
				if (grant_m1) begin
					if (starve) begin
						if (m1_rd) begin
							rsp_owner_m1 <= 1'b1;
							rsp_owner_m3 <= 1'b0;
							rsp_left <= {1'b0, m1_burstcnt};
							grant_m1 <= 1'b0;
							cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
						end else if (m1_we || !m1_want_s2) begin
							grant_m1 <= 1'b0;
							if (m1_we)
								cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
						end
					end else if (FAULT_LOST_READ) begin
						// 44981ab0 residual: m0 steals — revoke grant, lose lower.
						if (m0_live_cmd) begin
							grant_m1 <= 1'b0;
						end else if (m1_rd) begin
							rsp_owner_m1 <= 1'b1;
							rsp_owner_m3 <= 1'b0;
							rsp_left <= {1'b0, m1_burstcnt};
							grant_m1 <= 1'b0;
							cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
						end else if (m1_we || !m1_want_s2) begin
							grant_m1 <= 1'b0;
							if (m1_we)
								cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
						end
					end else begin
						// Product: exclusive grant until cmd done or want idle.
						// NEVER revoke for m0 while m1_want (bridge may arm next).
						if (m1_cmd) begin
							if (m1_rd) begin
								rsp_owner_m1 <= 1'b1;
								rsp_owner_m3 <= 1'b0;
								rsp_left <= {1'b0, m1_burstcnt};
								grant_m1 <= 1'b0;
								cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
							end else begin
								grant_m1 <= 1'b0;
								cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
							end
						end else if (!m1_want_s2) begin
							grant_m1 <= 1'b0;
						end
						// else hold grant_m1; m0 stays in skid
					end
				end else if (grant_m3) begin
					if (starve) begin
						if (m3_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b1;
							rsp_left <= {1'b0, m3_burstcnt};
							grant_m3 <= m3_want_s2;
							cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
						end else if (m3_we) begin
							cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
							grant_m3 <= m3_want_s2;
						end else if (!m3_want_s2) begin
							grant_m3 <= 1'b0;
						end
					end else if (FAULT_LOST_READ) begin
						// Lose collided lower: drop grant under m0, no m3 accept.
						if (m0_live_cmd) begin
							grant_m3 <= 1'b0;
						end else if (m3_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b1;
							rsp_left <= {1'b0, m3_burstcnt};
							grant_m3 <= 1'b0;
							cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
						end else if (m3_we || !m3_want_s2) begin
							grant_m3 <= 1'b0;
							if (m3_we)
								cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
						end
					end else begin
						// Product: exclusive grant_m3 — finish cmd or idle want.
						// Do NOT hand slot to m0 while m3_want (rd-duck WAIT hang).
						if (m3_cmd) begin
							if (m3_rd) begin
								rsp_owner_m1 <= 1'b0;
								rsp_owner_m3 <= 1'b1;
								rsp_left <= {1'b0, m3_burstcnt};
								grant_m3 <= 1'b0;
								cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
							end else begin
								grant_m3 <= 1'b0;
								cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
							end
						end else if (!m3_want_s2) begin
							grant_m3 <= 1'b0;
						end
						// else hold grant_m3; m0 skid
					end
				end else begin
					// Idle owner selection
					if (starve) begin
						if (m3_want_s2) begin
							grant_m3 <= 1'b1;
						end else if (m0_eff_rd_w) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b0;
							rsp_left <= {1'b0, m0_eff_burst};
							cnt_grant_m0 <= cnt_grant_m0 + 32'd1;
							m0_skid_v <= 1'b0;
						end else if (!m0_eff_cmd && m1_want_s2) begin
							grant_m1 <= 1'b1;
						end
					end else begin
						// Product: m0 (live/skid) first, then m1, then m3.
						// Do not re-grant m1/m3 while their rsp is in flight — bridge
						// may still hold a_rd until a_accept CDC arrives (rd-duck).
						if (m0_eff_rd_w) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b0;
							rsp_left <= {1'b0, m0_eff_burst};
							cnt_grant_m0 <= cnt_grant_m0 + 32'd1;
							m0_skid_v <= 1'b0;
						end else if (m0_eff_we_w) begin
							cnt_grant_m0 <= cnt_grant_m0 + 32'd1;
							m0_skid_v <= 1'b0;
						end else if (m1_want_s2 &&
						           !(rsp_active && rsp_owner_m1) &&
						           !(rsp_valid_r && rsp_owner_m1_r)) begin
							grant_m1 <= 1'b1;
						end else if (m3_want_s2 &&
						           !(rsp_active && rsp_owner_m3) &&
						           !(rsp_valid_r && rsp_owner_m3_r)) begin
							grant_m3 <= 1'b1;
						end
					end
				end
			end

			// No trailing grant-clear: write acceptance is only inside the
			// !DDRAM_BUSY && !rsp_pipe_active owner path. A free-running clear
			// would drop m1/m3_we while rsp_pipe is still draining another master.
		end
	end
endmodule

`default_nettype wire
