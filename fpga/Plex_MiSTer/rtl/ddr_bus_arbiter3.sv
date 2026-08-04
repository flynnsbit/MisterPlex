// Three-master f2sdram arbiter (w-mem) — product 2-master path untouched.
//
// Masters (all command ports sampled on clk = clk_ddr 90 MHz unless noted):
//   m0 — frame-store present READ (highest priority when commanding)
//   m2 — ddr_publish_engine / fabric bank fill (clk_ddr; RD+WE + doorbell)
//   m1 — bitstream ring READ (clk_m1 = clk_sys; want sync + rsp FIFO as product)
//
// Grant policy (when bus free / no rsp pipe):
//   1) m0_cmd wins immediately (scanout must not starve)
//   2) else if m2_want → grant_m2 (publish COPY/DIRECT or fabric bank fill)
//   3) else if m1_want → grant_m1
//
// CONTENTION (rd-duck open question — closed in sim, not on device):
//   Ideal peak @90 MHz × 8 B = 720 MB/s (port math, NOT measured HPS BW).
//   720p24 present RD = 33.1776 MB/s; COPY R+W = 66.3552; concurrent sum
//   ≈ 99.53 MB/s ≈ 13.8% of ideal peak. Engine also asserts present_want so
//   it issues no NEW cmd while m0 is commanding; arbiter quantum is the
//   second fence if an in-flight m2 beat is mid-accept.
//
// m2 sticky while m0 idle. When m0_cmd during m2 stream, release after at most
// M2_QUANTUM_BEATS accepted m2 cmds (default 8 ≈ LINE_COUNT refill slot).
// Whole-frame sticky lockout underruns m0 (rd-duck) — FAULT twin proves it.
//
// FAULT DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM: hold grant_m2 through continuous
// WE while m0_cmd for red twin (tests/rtl/ddr_publish_contended_tb.sv).
//
// M10K: no local arrays; m1 rsp async_fifo AW=3 × 64b data is WIDTH-BOUND
// (Cyclone V max native 40b). Same class as product 2-master arbiter FIFO →
// **2 M10K EST** (not ≤1 via bits/10240). Control analogy: nostub-poststrip1
// line_buf_ram DATA_W=64 → 2 M10K even at 2496 bits. ALM EST ~400–600; no fit.
//
// Do NOT replace ddr_bus_arbiter.sv in-place. Not in product files.qip until
// parent enables fabric publish after measured device BW.
//
`default_nettype none

module ddr_bus_arbiter3 #(
	// Max accepted m2 beats while m0 is commanding before yield.
	// 8 matches ddr_frame_store LINE_COUNT default (line-buffer depth).
	parameter int M2_QUANTUM_BEATS = 8
) (
	input  wire        clk,      // DDR bridge clock (90 MHz)
	input  wire        clk_m1,   // m1 consumer clock (20 MHz / clk_sys)
	input  wire        reset,    // synchronous to clk_m1 domain

	input  wire        m1_want,
	input  wire        m2_want,

	// --- m0 frame store ---
	output wire        m0_busy,
	input  wire  [7:0] m0_burstcnt,
	input  wire [28:0] m0_addr,
	output wire [63:0] m0_dout,
	output wire        m0_dout_ready,
	input  wire        m0_rd,
	input  wire [63:0] m0_din,
	input  wire  [7:0] m0_be,
	input  wire        m0_we,

	// --- m1 bitstream (clk_m1 domain on busy/dout_ready) ---
	output wire        m1_busy,
	input  wire  [7:0] m1_burstcnt,
	input  wire [28:0] m1_addr,
	output wire [63:0] m1_dout,
	output wire        m1_dout_ready,
	input  wire        m1_rd,
	input  wire [63:0] m1_din,
	input  wire  [7:0] m1_be,
	input  wire        m1_we,

	// --- m2 fabric writer (clk_ddr) ---
	output wire        m2_busy,
	input  wire  [7:0] m2_burstcnt,
	input  wire [28:0] m2_addr,
	output wire [63:0] m2_dout,
	output wire        m2_dout_ready,
	input  wire        m2_rd,
	input  wire [63:0] m2_din,
	input  wire  [7:0] m2_be,
	input  wire        m2_we,

	// --- physical DDRAM ---
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
	// reset: clk_m1 → clk_ddr
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
	reg m2_want_s1, m2_want_s2;
	always @(posedge clk) begin
		if (rst) begin
			m1_want_s1 <= 1'b0;
			m1_want_s2 <= 1'b0;
			m2_want_s1 <= 1'b0;
			m2_want_s2 <= 1'b0;
		end else begin
			m1_want_s1 <= m1_want;
			m1_want_s2 <= m1_want_s1;
			// m2_want is already clk_ddr — still double-register for uniformity
			m2_want_s1 <= m2_want;
			m2_want_s2 <= m2_want_s1;
		end
	end

	// grant one-hot among {m1, m2}; m0 is default when both grants low
	reg grant_m1;
	reg grant_m2;
	// When m0 and m2 both want: alternate so neither starves (scanout glitch vs drop).
	reg fair_pref_m2;
	// Remaining accepted m2 cmds allowed while m0_cmd before forced yield.
	reg [7:0] m2_quantum_cnt;
	localparam [7:0] M2_QMAX = (M2_QUANTUM_BEATS < 1) ? 8'd1 :
	                           (M2_QUANTUM_BEATS > 255) ? 8'd255 :
	                           8'(M2_QUANTUM_BEATS);
	reg rsp_owner_m1;
	reg rsp_owner_m2;
	reg [8:0] rsp_left;
	reg [63:0] rsp_data_r;
	reg        rsp_valid_r;
	reg        rsp_owner_m1_r;
	reg        rsp_owner_m2_r;

	wire rsp_active = rsp_left != 9'd0;
	wire rsp_pipe_active = rsp_active | rsp_valid_r;
	wire m0_cmd = m0_rd | m0_we;
	wire m1_cmd = m1_rd | m1_we;
	wire m2_cmd = m2_rd | m2_we;

	wire use_m1 = grant_m1;
	wire use_m2 = grant_m2 && !grant_m1;
	wire [7:0] selected_burst =
		use_m1 ? m1_burstcnt :
		use_m2 ? m2_burstcnt : m0_burstcnt;

	// Busy: block a master when someone else owns the bus or rsp pipe.
	assign m0_busy = DDRAM_BUSY | grant_m1 | grant_m2 |
	                 (rsp_active & (rsp_owner_m1 | rsp_owner_m2)) |
	                 (rsp_valid_r & (rsp_owner_m1_r | rsp_owner_m2_r));

	// Registered busy (same shape as historical m2 path). Publish engine
	// solo COPY is verified direct-to-bridge in engine TB; contended path
	// uses quantum G1 continuous-WE (not engine single-beat WR through arb).
	wire m2_busy_comb = DDRAM_BUSY | grant_m1 | !grant_m2 |
	                    (rsp_active & !rsp_owner_m2) |
	                    (rsp_valid_r & !rsp_owner_m2_r);
	reg m2_busy_r;
	always @(posedge clk) begin
		if (rst)
			m2_busy_r <= 1'b1;
		else
			m2_busy_r <= m2_busy_comb;
	end
	assign m2_busy = m2_busy_r;

	wire m1_busy_comb = DDRAM_BUSY | !grant_m1 | grant_m2 |
	                    (rsp_active & !rsp_owner_m1) |
	                    (rsp_valid_r & !rsp_owner_m1_r);
	reg m1_busy_r;
	always @(posedge clk) begin
		if (rst)
			m1_busy_r <= 1'b1;
		else
			m1_busy_r <= m1_busy_comb;
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

	assign DDRAM_BURSTCNT = use_m1 ? m1_burstcnt : (use_m2 ? m2_burstcnt : m0_burstcnt);
	assign DDRAM_ADDR     = use_m1 ? m1_addr      : (use_m2 ? m2_addr      : m0_addr);
	assign DDRAM_RD       = use_m1 ? m1_rd        : (use_m2 ? m2_rd        : m0_rd);
	assign DDRAM_DIN      = use_m1 ? m1_din       : (use_m2 ? m2_din       : m0_din);
	assign DDRAM_BE       = use_m1 ? m1_be        : (use_m2 ? m2_be        : m0_be);
	assign DDRAM_WE       = use_m1 ? m1_we        : (use_m2 ? m2_we        : m0_we);

	wire rsp_raw_valid = DDRAM_DOUT_READY & rsp_active;

	assign m0_dout = rsp_data_r;
	assign m0_dout_ready = rsp_valid_r & !rsp_owner_m1_r & !rsp_owner_m2_r;

	assign m2_dout = rsp_data_r;
	assign m2_dout_ready = rsp_valid_r & rsp_owner_m2_r;

	// m1 response FIFO (clk_ddr → clk_m1) — same beat-conservation need as product
	wire        m1_rsp_fifo_full;
	wire        m1_rsp_fifo_empty;
	wire [63:0] m1_rsp_fifo_rdata;
	wire        m1_rsp_wr_en = rsp_valid_r & rsp_owner_m1_r;

	async_fifo #(.WIDTH(64), .AW(3)) m1_rsp_fifo (
		.wr_clk   (clk),
		.wr_reset (rst),
		.wr_en    (m1_rsp_wr_en),
		.wr_data  (rsp_data_r),
		.wr_full  (m1_rsp_fifo_full),
		.wr_almost_full (),
		.rd_clk   (clk_m1),
		.rd_reset (reset),
		.rd_en    (!m1_rsp_fifo_empty),
		.rd_data  (m1_rsp_fifo_rdata),
		.rd_empty (m1_rsp_fifo_empty)
	);

	assign m1_dout       = m1_rsp_fifo_rdata;
	assign m1_dout_ready = !m1_rsp_fifo_empty;

	wire _unused_full = m1_rsp_fifo_full;

	always @(posedge clk) begin
		if (rst) begin
			grant_m1 <= 1'b0;
			grant_m2 <= 1'b0;
			fair_pref_m2 <= 1'b0; // first tie → prefer m0 (scanout)
			m2_quantum_cnt <= M2_QMAX;
			rsp_owner_m1 <= 1'b0;
			rsp_owner_m2 <= 1'b0;
			rsp_left <= 9'd0;
			rsp_data_r <= 64'd0;
			rsp_valid_r <= 1'b0;
			rsp_owner_m1_r <= 1'b0;
			rsp_owner_m2_r <= 1'b0;
		end else begin
			rsp_valid_r <= rsp_raw_valid;
			if (rsp_raw_valid) begin
				rsp_data_r <= DDRAM_DOUT;
				rsp_owner_m1_r <= rsp_owner_m1;
				rsp_owner_m2_r <= rsp_owner_m2;
			end

			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			if (!DDRAM_BUSY && !rsp_pipe_active) begin
				if (grant_m1) begin
					if (m1_rd) begin
						rsp_owner_m1 <= 1'b1;
						rsp_owner_m2 <= 1'b0;
						rsp_left <= {1'b0, selected_burst};
						grant_m1 <= 1'b0;
					end else if (m1_we || !m1_want_s2 ||
					            (m2_want_s2 && !m1_cmd)) begin
						// Yield to m2 if m1 holds want without a command
						// (TB + idle bitstream); avoids sticky m1 lockout.
						grant_m1 <= 1'b0;
					end
				end else if (grant_m2) begin
					// Sticky while m0 idle (full-frame WE OK). With m0_cmd:
					// product bounds sticky to M2_QUANTUM_BEATS accepted cmds
					// then yields so scanout refills before LINE_COUNT drains.
					if (m2_rd) begin
						rsp_owner_m1 <= 1'b0;
						rsp_owner_m2 <= 1'b1;
						rsp_left <= {1'b0, selected_burst};
						grant_m2 <= 1'b0;
					end else if (!m2_want_s2 && !m2_cmd) begin
						grant_m2 <= 1'b0;
					end else if (m0_cmd && !m2_cmd) begin
						grant_m2 <= 1'b0; // gap / drain → scanout
`ifndef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
					end else if (m0_cmd && m2_cmd) begin
						// Current beat still issues this cycle (grant_m2 held
						// combinationally); drop grant for next cycle at quantum.
						if (m2_quantum_cnt <= 8'd1) begin
							grant_m2 <= 1'b0;
							m2_quantum_cnt <= M2_QMAX;
							fair_pref_m2 <= 1'b0; // next tie prefers m0
						end else begin
							m2_quantum_cnt <= m2_quantum_cnt - 8'd1;
						end
`endif
					end
					// FAULT / no m0: hold sticky through continuous WE stream
				end else begin
					// idle owner = m0 path, with m0/m2 fair share when both demand
					if (m0_cmd && m2_want_s2) begin
						if (fair_pref_m2) begin
							grant_m2 <= 1'b1;
							m2_quantum_cnt <= M2_QMAX;
							fair_pref_m2 <= 1'b0;
						end else if (m0_rd) begin
							rsp_owner_m1 <= 1'b0;
							rsp_owner_m2 <= 1'b0;
							rsp_left <= {1'b0, selected_burst};
							fair_pref_m2 <= 1'b1;
						end else begin
							// m0_we without rd — still count as m0 turn
							fair_pref_m2 <= 1'b1;
						end
					end else if (m0_rd) begin
						rsp_owner_m1 <= 1'b0;
						rsp_owner_m2 <= 1'b0;
						rsp_left <= {1'b0, selected_burst};
					end else if (!m0_cmd && m2_want_s2) begin
						grant_m2 <= 1'b1;
						m2_quantum_cnt <= M2_QMAX;
					end else if (!m0_cmd && m1_want_s2) begin
						grant_m1 <= 1'b1;
					end
				end
			end

			// m1 write: drop grant after accepted non-read cmd (product behaviour)
			if (grant_m1 && !DDRAM_BUSY && m1_cmd && !m1_rd)
				grant_m1 <= 1'b0;
			// m2 WE release handled above (quantum / m0 pre-empt)
		end
	end
endmodule

`default_nettype wire
