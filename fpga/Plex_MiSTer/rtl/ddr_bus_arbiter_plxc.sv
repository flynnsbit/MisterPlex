// ddr_bus_arbiter_plxc — product 2-master + PLXC (m3) lowest-priority slot
//
// Masters (clk_ddr domain arbitration):
//   m0 — video frame store (scanout). Absolute priority when commanding.
//   m1 — bitstream/PLXG path (clk_m1 domain, async FIFO responses).
//   m3 — PLXC chrome loader (clk_m3 domain, async FIFO responses).
//
// Priority (product STARVE_VIDEO=0):
//   1) m0_cmd always wins idle slots and preempts m3 want.
//   2) else m1_want
//   3) else m3_want
//
// STARVE_VIDEO=1 (red twin only): m3 sticky over m0 — must produce underrun
// in the concurrent-load TB. Never synthesize product with STARVE_VIDEO=1.

`timescale 1ns / 1ps
`default_nettype none

module ddr_bus_arbiter_plxc #(
	// Compile-time default; runtime starve_video overrides when driven 1 in TB.
	parameter bit STARVE_VIDEO = 1'b0
) (
	input  wire        clk,      // DDR bridge clock (90 MHz)
	input  wire        clk_m1,   // m1 consumer clock (20 MHz)
	input  wire        clk_m3,   // m3 PLXC consumer clock (usually clk_sys)
	input  wire        reset,    // synchronous to clk_m1/m3 domain
	// Red-twin / product select (OR'd with parameter). Product ties 0.
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

	output wire        m3_busy,
	input  wire  [7:0] m3_burstcnt,
	input  wire [28:0] m3_addr,
	output wire [63:0] m3_dout,
	output wire        m3_dout_ready,
	input  wire        m3_rd,
	input  wire [63:0] m3_din,
	input  wire  [7:0] m3_be,
	input  wire        m3_we,

	// observability (clk domain)
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

	wire rsp_active = rsp_left != 9'd0;
	wire rsp_pipe_active = rsp_active | rsp_valid_r;
	wire m0_cmd = m0_rd | m0_we;
	wire m1_cmd = m1_rd | m1_we;
	wire m3_cmd = m3_rd | m3_we;

	wire use_m1 = grant_m1;
	wire use_m3 = grant_m3 && !grant_m1;
	wire [7:0] selected_burst =
		use_m1 ? m1_burstcnt :
		use_m3 ? m3_burstcnt : m0_burstcnt;

	assign grant_m3_live = grant_m3;

	// m0 blocked only by other owners / their responses — never by m3 sticky
	// when STARVE_VIDEO=0 and m0 is commanding (see grant logic).
	assign m0_busy = DDRAM_BUSY | grant_m1 | grant_m3 |
	                 (rsp_active & (rsp_owner_m1 | rsp_owner_m3)) |
	                 (rsp_valid_r & (rsp_owner_m1_r | rsp_owner_m3_r));

	wire m1_busy_comb = DDRAM_BUSY | !grant_m1 |
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

	assign DDRAM_BURSTCNT = use_m1 ? m1_burstcnt : (use_m3 ? m3_burstcnt : m0_burstcnt);
	assign DDRAM_ADDR     = use_m1 ? m1_addr      : (use_m3 ? m3_addr      : m0_addr);
	assign DDRAM_RD       = use_m1 ? m1_rd        : (use_m3 ? m3_rd        : m0_rd);
	assign DDRAM_DIN      = use_m1 ? m1_din       : (use_m3 ? m3_din       : m0_din);
	assign DDRAM_BE       = use_m1 ? m1_be        : (use_m3 ? m3_be        : m0_be);
	assign DDRAM_WE       = use_m1 ? m1_we        : (use_m3 ? m3_we        : m0_we);

	wire rsp_raw_valid = DDRAM_DOUT_READY & rsp_active;

	assign m0_dout = rsp_data_r;
	assign m0_dout_ready = rsp_valid_r & !rsp_owner_m1_r & !rsp_owner_m3_r;

	// m1 response FIFO
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

	// m3 response FIFO (PLXC on clk_m3)
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
		end else begin
			rsp_valid_r <= rsp_raw_valid;
			if (rsp_raw_valid) begin
				rsp_data_r <= DDRAM_DOUT;
				rsp_owner_m1_r <= rsp_owner_m1;
				rsp_owner_m3_r <= rsp_owner_m3;
			end

			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			if (!DDRAM_BUSY && !rsp_pipe_active) begin
				if (grant_m1) begin
					if (m1_rd) begin
						rsp_owner_m1 <= 1'b1;
						rsp_owner_m3 <= 1'b0;
						rsp_left <= {1'b0, selected_burst};
						grant_m1 <= 1'b0;
						cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
					end else if (m1_we || !m1_want_s2) begin
						grant_m1 <= 1'b0;
						if (m1_we)
							cnt_grant_m1 <= cnt_grant_m1 + 32'd1;
					end
				end else if (grant_m3) begin
					if (starve) begin
						// Red twin: sticky m3 while want — starve m0 intentionally.
						if (m3_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b1;
							rsp_left <= {1'b0, selected_burst};
							grant_m3 <= m3_want_s2;
							cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
						end else if (m3_we) begin
							cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
							grant_m3 <= m3_want_s2;
						end else if (!m3_want_s2) begin
							grant_m3 <= 1'b0;
						end
					end else begin
						// Product: m0 preempts m3 immediately when commanding.
						if (m0_cmd) begin
							grant_m3 <= 1'b0;
						end else if (m3_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b1;
							rsp_left <= {1'b0, selected_burst};
							grant_m3 <= 1'b0;
							cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
						end else if (m3_we || !m3_want_s2) begin
							grant_m3 <= 1'b0;
							if (m3_we)
								cnt_grant_m3 <= cnt_grant_m3 + 32'd1;
						end
					end
				end else begin
					// Idle owner selection
					if (starve) begin
						if (m3_want_s2) begin
							grant_m3 <= 1'b1;
						end else if (m0_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b0;
							rsp_left <= {1'b0, selected_burst};
							cnt_grant_m0 <= cnt_grant_m0 + 32'd1;
						end else if (!m0_cmd && m1_want_s2) begin
							grant_m1 <= 1'b1;
						end
					end else begin
						// Product: m0 first, then m1, then m3
						if (m0_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m3 <= 1'b0;
							rsp_left <= {1'b0, selected_burst};
							cnt_grant_m0 <= cnt_grant_m0 + 32'd1;
						end else if (m0_cmd) begin
							cnt_grant_m0 <= cnt_grant_m0 + 32'd1;
						end else if (m1_want_s2) begin
							grant_m1 <= 1'b1;
						end else if (m3_want_s2) begin
							grant_m3 <= 1'b1;
						end
					end
				end
			end

			// Single-beat WE complete: drop grant after accepted WE (non-starve)
			if (!starve) begin
				if (grant_m1 && !DDRAM_BUSY && m1_cmd && !m1_rd)
					grant_m1 <= 1'b0;
				if (grant_m3 && !DDRAM_BUSY && m3_cmd && !m3_rd)
					grant_m3 <= 1'b0;
			end
		end
	end
endmodule

`default_nettype wire
