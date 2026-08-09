// Two-master f2sdram arbiter for the single HPS DDR port.
//
// Master 0 is the video frame store — both master and arbiter share clk
// (the DDR bridge clock, general[2].gpll, 90 MHz).
//
// Master 1 is the compressed-bitstream ring reader on the system clock
// (general[0].gpll, 20 MHz).  clk_m1 carries the consumer's clock so
// that DDR read responses can be safely forwarded via an async FIFO.
// m1_want gets a 2-FF synchroniser; data/address signals are protocol-
// guarded (stable while m1_busy is deasserted).
//
// ⚠ This module previously ran on clk_sys (20 MHz) which placed its
// registered state (rsp_left, grant_m1) between the 90 MHz DDR bridge
// and the 90 MHz frame store, creating a 5.555 ns setup path that
// failed STA by −1.346 ns.  Moving to clk_ddr eliminates that crossing.
//
// ⚠ m1_dout_ready is a single clk_ddr pulse (11.1 ns).  The 20 MHz
// consumer misses ~70 % of pulses depending on DDR CAS alignment.
// An async_fifo on the m1 response path absorbs the rate difference:
// write on clk_ddr, auto-pop read on clk_m1.  Beat-conservation test
// confirmed 7/10 drops WITHOUT the FIFO, 0/10 WITH it.

module ddr_bus_arbiter (
	input  wire        clk,      // DDR bridge clock (90 MHz)
	input  wire        clk_m1,   // m1 consumer clock (20 MHz / clk_sys)
	input  wire        reset,    // synchronous to clk_m1 domain

	input  wire        m1_want,

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
	// o40: consumer must pop FWFT response; auto-pop dropped beats before
	// ST_POLL sampled (o35 live telem_seq=1 / cons=0).
	input  wire        m1_rsp_pop,

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
	// Reset synchroniser (reset originates in clk_sys, we run on clk_ddr)
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

	// 2-FF synchroniser for m1_want (clk_sys → clk_ddr)
	reg m1_want_s1, m1_want_s2;
	always @(posedge clk) begin
		if (rst) begin
			m1_want_s1 <= 1'b0;
			m1_want_s2 <= 1'b0;
		end else begin
			m1_want_s1 <= m1_want;
			m1_want_s2 <= m1_want_s1;
		end
	end

	// o25: lower-density lost-pulse recovery vs o24.
	// Root cause unchanged: m1_rd/m1_we are single-cycle clk_m1 pulses; sampling
	// them only while grant_m1 on clk_ddr drops CTRL/DATA → cons=0.
	// o24 stuck those pulses with 2FF+sticky *and* latched addr/burst/din/be on
	// clk_ddr (~109 extra FFs into the DDRAM_* mux) → STA −0.674 NODEPLOY.
	// o25: sticky req lives on clk_m1; clk_ddr only 2FF-syncs the levels and
	// returns a 1-bit ack. Addr/burst/din/be stay on the live m1_* nets
	// (protocol-stable from issue until the next command).
	reg m1_rd_req, m1_we_req;
	reg m1_rd_ack, m1_we_ack;
	reg m1_rd_ack_s1, m1_rd_ack_s2;
	reg m1_we_ack_s1, m1_we_ack_s2;
	reg m1_rd_req_s1, m1_rd_req_s2;
	reg m1_we_req_s1, m1_we_req_s2;

	always @(posedge clk_m1) begin
		if (reset) begin
			m1_rd_req <= 1'b0;
			m1_we_req <= 1'b0;
			m1_rd_ack_s1 <= 1'b0;
			m1_rd_ack_s2 <= 1'b0;
			m1_we_ack_s1 <= 1'b0;
			m1_we_ack_s2 <= 1'b0;
		end else begin
			m1_rd_ack_s1 <= m1_rd_ack;
			m1_rd_ack_s2 <= m1_rd_ack_s1;
			m1_we_ack_s1 <= m1_we_ack;
			m1_we_ack_s2 <= m1_we_ack_s1;

			if (m1_rd)
				m1_rd_req <= 1'b1;
			else if (m1_rd_ack_s2)
				m1_rd_req <= 1'b0;

			if (m1_we)
				m1_we_req <= 1'b1;
			else if (m1_we_ack_s2)
				m1_we_req <= 1'b0;
		end
	end

	reg grant_m1;
	reg rsp_owner_m1;
	reg [8:0] rsp_left;
	reg [63:0] rsp_data_r;
	reg        rsp_valid_r;
	reg        rsp_owner_m1_r;
	// Fairness: present (m0) streams continuous frame-store reads and can
	// starve bitstream m1 forever (o13: PLXR telem_seq stuck at 1, consumer=0
	// while host PLXB producer filled 256KiB). After M1_WAIT_MAX ddr cycles of
	// pending m1_want without grant, block new m0_rd starts so m1 gets a slot.
	reg [5:0] m1_wait;
	localparam [5:0] M1_WAIT_MAX = 6'd32;
	wire m1_starved = m1_want_s2 && (m1_wait >= M1_WAIT_MAX);

	// ready = req visible on clk_ddr and not yet acked (prevents double-accept
	// during the req/ack drain back to clk_m1).
	wire m1_rd_ready = m1_rd_req_s2 & ~m1_rd_ack;
	wire m1_we_ready = m1_we_req_s2 & ~m1_we_ack;
	wire rsp_active = rsp_left != 9'd0;
	wire rsp_pipe_active = rsp_active | rsp_valid_r;
	wire m0_cmd = m0_rd | m0_we;
	wire m1_cmd = m1_rd_ready | m1_we_ready;

	// When m1 has waited M1_WAIT_MAX without a grant, raise m0_busy so the
	// frame-store stops issuing new reads and the pipe can drain — otherwise
	// continuous m0_rd keeps rsp_pipe_active and m1 never enters the
	// !rsp_pipe_active grant window (o14 still cons=0 / telem_seq=1).
	assign m0_busy = DDRAM_BUSY | grant_m1 | m1_starved |
	                 (rsp_active & rsp_owner_m1) |
	                 (rsp_valid_r & rsp_owner_m1_r);

	// m1_busy: register on clk_ddr to eliminate combinational glitches,
	// then 2-FF sync to clk_m1 for proper CDC.  The consumer uses this
	// only as a level gate (!busy before issuing commands), so the ~100ns
	// sync latency just delays the next command — no protocol breakage.
	wire m1_busy_comb = DDRAM_BUSY | !grant_m1 |
	                    (rsp_active & !rsp_owner_m1) |
	                    (rsp_valid_r & !rsp_owner_m1_r);
	reg  m1_busy_r;
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

	// o26: register DDRAM_* command port on clk_ddr.
	// o25 drove a wide combo mux (use_m1 ? m1_* : m0_*) straight into the HPS
	// f2sdram bridge → density STA −0.458 on general[2] (ddr clk). Registering
	// the post-mux command beats cuts that combo cone. Protocol: while
	// DDRAM_BUSY, hold the last command; when free, RD/WE are single-cycle
	// pulses issued in the same FSM step that opens rsp_left / acks m1.
	// m1 addr/burst/din/be remain live (stable while sticky req held).
	reg  [7:0] ddram_burstcnt_q;
	reg [28:0] ddram_addr_q;
	reg        ddram_rd_q;
	reg [63:0] ddram_din_q;
	reg  [7:0] ddram_be_q;
	reg        ddram_we_q;

	assign DDRAM_BURSTCNT = ddram_burstcnt_q;
	assign DDRAM_ADDR     = ddram_addr_q;
	assign DDRAM_RD       = ddram_rd_q;
	assign DDRAM_DIN      = ddram_din_q;
	assign DDRAM_BE       = ddram_be_q;
	assign DDRAM_WE       = ddram_we_q;

	wire [63:0] ddram_dout_pad;
	wire        ddram_dout_ready_pad;
	genvar rsp_pad_i;
	generate
		for (rsp_pad_i = 0; rsp_pad_i < 64; rsp_pad_i = rsp_pad_i + 1) begin : gen_rsp_in_pad
			mplex_hold_lcell rsp_data_in_pad (
				.din  (DDRAM_DOUT[rsp_pad_i]),
				.dout (ddram_dout_pad[rsp_pad_i])
			);
		end
	endgenerate
	mplex_hold_lcell rsp_ready_in_pad (
		.din  (DDRAM_DOUT_READY),
		.dout (ddram_dout_ready_pad)
	);

	wire [63:0] rsp_data_out_pad;
	wire        rsp_valid_out_pad;
	wire        rsp_owner_m1_out_pad;
	generate
		for (rsp_pad_i = 0; rsp_pad_i < 64; rsp_pad_i = rsp_pad_i + 1) begin : gen_rsp_out_pad
			mplex_hold_lcell rsp_data_out_pad_i (
				.din  (rsp_data_r[rsp_pad_i]),
				.dout (rsp_data_out_pad[rsp_pad_i])
			);
		end
	endgenerate
	mplex_hold_lcell rsp_valid_out_pad_i (
		.din  (rsp_valid_r),
		.dout (rsp_valid_out_pad)
	);
	mplex_hold_lcell rsp_owner_out_pad_i (
		.din  (rsp_owner_m1_r),
		.dout (rsp_owner_m1_out_pad)
	);

	wire rsp_raw_valid = ddram_dout_ready_pad & rsp_active;

	assign m0_dout = rsp_data_out_pad;
	assign m0_dout_ready = rsp_valid_out_pad & !rsp_owner_m1_out_pad;

	// ── m1 response FIFO (clk_ddr → clk_m1) ──
	// DDRAM_DOUT_READY is a single clk_ddr pulse per beat.  The clk_m1
	// (20 MHz) consumer would miss ~70 % of those pulses if sampled
	// directly.  The FIFO absorbs beats on the fast side. o40: do NOT
	// auto-pop — hold FWFT word until m1_rsp_pop (reader/DPB sampled it).
	// Auto-pop made ready a one-cycle pulse; if ST_POLL missed it, cons=0
	// forever (o35 live: telem_seq stuck at 1, PLXR=0, host PLXB advancing).
	wire        m1_rsp_fifo_full;
	wire        m1_rsp_fifo_empty;
	wire [63:0] m1_rsp_fifo_rdata;
	wire        m1_rsp_wr_en = rsp_valid_out_pad & rsp_owner_m1_out_pad;

	// o28: AW 3→2 (depth 8→4). o27 pad-strip regressed STA; restore o26 pads
	// and cut only FIFO depth (CAS burst beats rarely need 8).
	async_fifo #(.WIDTH(64), .AW(2)) m1_rsp_fifo (
		.wr_clk   (clk),
		.wr_reset (rst),
		.wr_en    (m1_rsp_wr_en),
		.wr_data  (rsp_data_out_pad),
		.wr_full  (m1_rsp_fifo_full),
		.wr_almost_full (),

		.rd_clk   (clk_m1),
		.rd_reset (reset),       // reset is synchronous to clk_m1
		.rd_en    (m1_rsp_pop && !m1_rsp_fifo_empty),
		.rd_data  (m1_rsp_fifo_rdata),
		.rd_empty (m1_rsp_fifo_empty)
	);

	assign m1_dout       = m1_rsp_fifo_rdata;
	assign m1_dout_ready = !m1_rsp_fifo_empty;

	always @(posedge clk) begin
		if (rst) begin
			grant_m1 <= 1'b0;
			rsp_owner_m1 <= 1'b0;
			rsp_left <= 9'd0;
			rsp_data_r <= 64'd0;
			rsp_valid_r <= 1'b0;
			rsp_owner_m1_r <= 1'b0;
			m1_wait <= 6'd0;
			m1_rd_req_s1 <= 1'b0;
			m1_rd_req_s2 <= 1'b0;
			m1_we_req_s1 <= 1'b0;
			m1_we_req_s2 <= 1'b0;
			m1_rd_ack <= 1'b0;
			m1_we_ack <= 1'b0;
			ddram_burstcnt_q <= 8'd0;
			ddram_addr_q <= 29'd0;
			ddram_rd_q <= 1'b0;
			ddram_din_q <= 64'd0;
			ddram_be_q <= 8'd0;
			ddram_we_q <= 1'b0;
		end else begin
			// 2-FF sync req levels (clk_m1 → clk_ddr)
			m1_rd_req_s1 <= m1_rd_req;
			m1_rd_req_s2 <= m1_rd_req_s1;
			m1_we_req_s1 <= m1_we_req;
			m1_we_req_s2 <= m1_we_req_s1;

			// 4-phase drain: drop ack once source req has fallen.
			if (!m1_rd_req_s2)
				m1_rd_ack <= 1'b0;
			if (!m1_we_req_s2)
				m1_we_ack <= 1'b0;

			rsp_valid_r <= rsp_raw_valid;
			if (rsp_raw_valid) begin
				rsp_data_r <= ddram_dout_pad;
				rsp_owner_m1_r <= rsp_owner_m1;
			end

			if (DDRAM_DOUT_READY && rsp_active)
				rsp_left <= rsp_left - 9'd1;

			// Count consecutive ddr cycles m1 wants but is not granted.
			if (!m1_want_s2 || grant_m1)
				m1_wait <= 6'd0;
			else if (m1_wait != 6'h3f)
				m1_wait <= m1_wait + 6'd1;

			// Hold command while HPS asserts BUSY; otherwise drop one-shot RD/WE
			// unless re-issued below in the same cycle.
			if (!DDRAM_BUSY) begin
				ddram_rd_q <= 1'b0;
				ddram_we_q <= 1'b0;
			end

			if (!DDRAM_BUSY && !rsp_pipe_active) begin
				if (grant_m1) begin
					if (m1_rd_ready) begin
						ddram_burstcnt_q <= m1_burstcnt;
						ddram_addr_q     <= m1_addr;
						ddram_rd_q       <= 1'b1;
						ddram_din_q      <= m1_din;
						ddram_be_q       <= m1_be;
						ddram_we_q       <= 1'b0;
						rsp_owner_m1 <= 1'b1;
						rsp_left <= {1'b0, m1_burstcnt};
						grant_m1 <= 1'b0;
						m1_rd_ack <= 1'b1;
						m1_wait <= 6'd0;
					end else if (m1_we_ready) begin
						// Posted write: one registered WE beat while granted.
						ddram_burstcnt_q <= m1_burstcnt;
						ddram_addr_q     <= m1_addr;
						ddram_rd_q       <= 1'b0;
						ddram_din_q      <= m1_din;
						ddram_be_q       <= m1_be;
						ddram_we_q       <= 1'b1;
						grant_m1 <= 1'b0;
						m1_we_ack <= 1'b1;
						m1_wait <= 6'd0;
					end else if (!m1_want_s2) begin
						grant_m1 <= 1'b0;
						m1_wait <= 6'd0;
					end
				end else begin
					// Prefer m1 when idle-gap OR when starved by continuous m0_rd.
					// Also take m1 if a ready cmd is already waiting (lost-RD recovery).
					if ((m1_want_s2 || m1_cmd) && (!m0_cmd || m1_starved || m1_cmd)) begin
						grant_m1 <= 1'b1;
					end else if (m0_rd) begin
						ddram_burstcnt_q <= m0_burstcnt;
						ddram_addr_q     <= m0_addr;
						ddram_rd_q       <= 1'b1;
						ddram_din_q      <= m0_din;
						ddram_be_q       <= m0_be;
						ddram_we_q       <= 1'b0;
						rsp_owner_m1 <= 1'b0;
						rsp_left <= {1'b0, m0_burstcnt};
					end else if (m0_we) begin
						ddram_burstcnt_q <= m0_burstcnt;
						ddram_addr_q     <= m0_addr;
						ddram_rd_q       <= 1'b0;
						ddram_din_q      <= m0_din;
						ddram_be_q       <= m0_be;
						ddram_we_q       <= 1'b1;
					end
				end
			end
		end
	end
endmodule
