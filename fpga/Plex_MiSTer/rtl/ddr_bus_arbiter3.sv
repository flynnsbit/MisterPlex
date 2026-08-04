// Three-master f2sdram arbiter (w-mem) — sticky-grant pass-through.
//
// Data path while owner==m2 is wire-identical to a direct DMA hookup.
// Owner is sticky to m2 for the whole m2_want window, except quantum yield
// to m0 at a command gap (!m2_rd && !m2_we && !wr_lock) after Q beats.
// Write-burst lock prevents mid-burst revoke (rd-duck / f2sdram_safe_terminator).
//
// M10K: m1 async_fifo ramstyle=MLAB → **0 M10K** (not 2).
// Control: nostub-poststrip1 Plex.fit.rpt L5258-5259
//   |ddr_bus_arbiter:ddr_arb| M10Ks=0 BlockMemBits=0
//   |async_fifo:m1_rsp_fifo|  M10Ks=0 BlockMemBits=0 ALMs_for_memory=0
// ALM EST ~400 (fit ddr_arb 338.3 incl. children).
`default_nettype none

module ddr_bus_arbiter3 #(
	parameter int M2_QUANTUM_BEATS = 8
) (
	input  wire        clk,
	input  wire        clk_m1,
	input  wire        reset,
	input  wire        m1_want,
	input  wire        m2_want,
	input  wire        m2_yield_window, // DMA ST_YIELD (or 1 when m2 idle/CWE)
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
	output wire        m2_busy,
	input  wire  [7:0] m2_burstcnt,
	input  wire [28:0] m2_addr,
	output wire [63:0] m2_dout,
	output wire        m2_dout_ready,
	input  wire        m2_rd,
	input  wire [63:0] m2_din,
	input  wire  [7:0] m2_be,
	input  wire        m2_we,
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
	reg reset_s1, reset_s2;
	always @(posedge clk or posedge reset) begin
		if (reset) begin reset_s1 <= 1'b1; reset_s2 <= 1'b1;
		end else begin reset_s1 <= 1'b0; reset_s2 <= reset_s1; end
	end
	wire rst = reset_s2;

	reg m1w1, m1w2;
	always @(posedge clk) begin
		if (rst) begin m1w1 <= 0; m1w2 <= 0;
		end else begin m1w1 <= m1_want; m1w2 <= m1w1; end
	end

	localparam [7:0] QMAX = (M2_QUANTUM_BEATS < 1) ? 8'd1 :
	                        (M2_QUANTUM_BEATS > 255) ? 8'd255 :
	                        8'(M2_QUANTUM_BEATS);

	reg [1:0] owner /* verilator public_flat_rd */;
	reg [7:0] wr_left /* verilator public_flat_rd */;
	reg [7:0] rd_left /* verilator public_flat_rd */; // m2/m0 read data beats remaining
	reg [7:0] qcnt /* verilator public_flat_rd */;
	reg       m0_pri /* verilator public_flat_rd */;
	reg       m0_rsp /* verilator public_flat_rd */; // m0 read data pending

	// Lock owner for entire write burst AND entire read response window.
	wire wr_lock = (wr_left != 8'd0);
	wire rd_lock = (rd_left != 8'd0);
	wire xact_lock = wr_lock | rd_lock;
	wire use1 = (owner == 2'd1);
	wire use2 = (owner == 2'd2);

	wire [7:0]  sel_bc = use1 ? m1_burstcnt : (use2 ? m2_burstcnt : m0_burstcnt);
	wire        sel_rd = use1 ? m1_rd       : (use2 ? m2_rd       : m0_rd);
	wire        sel_we = use1 ? m1_we       : (use2 ? m2_we       : m0_we);
	wire [28:0] sel_ad = use1 ? m1_addr     : (use2 ? m2_addr     : m0_addr);
	wire [63:0] sel_di = use1 ? m1_din      : (use2 ? m2_din      : m0_din);
	wire [7:0]  sel_be = use1 ? m1_be       : (use2 ? m2_be       : m0_be);

	// Pure pass-through while granted — identical to direct DMA hookup.
	assign m2_busy       = DDRAM_BUSY | (owner != 2'd2);
	assign m2_dout       = DDRAM_DOUT;
	assign m2_dout_ready = DDRAM_DOUT_READY & (owner == 2'd2);

	assign m0_busy       = DDRAM_BUSY | (owner != 2'd0);
	assign m0_dout       = DDRAM_DOUT;
	assign m0_dout_ready = DDRAM_DOUT_READY & (owner == 2'd0);

	wire m1b_c = DDRAM_BUSY | (owner != 2'd1);
	reg m1b_r, m1b_s1, m1b_s2;
	always @(posedge clk) begin
		if (rst) m1b_r <= 1'b1; else m1b_r <= m1b_c;
	end
	always @(posedge clk_m1) begin
		if (reset) begin m1b_s1 <= 1; m1b_s2 <= 1;
		end else begin m1b_s1 <= m1b_r; m1b_s2 <= m1b_s1; end
	end
	assign m1_busy = m1b_s2;

	assign DDRAM_BURSTCNT = sel_bc;
	assign DDRAM_ADDR     = sel_ad;
	assign DDRAM_RD       = sel_rd;
	assign DDRAM_DIN      = sel_di;
	assign DDRAM_BE       = sel_be;
	assign DDRAM_WE       = sel_we;

	wire f_full, f_empty;
	wire [63:0] f_dout;
	async_fifo #(.WIDTH(64), .AW(3)) m1_rsp_fifo (
		.wr_clk(clk), .wr_reset(rst),
		.wr_en(DDRAM_DOUT_READY & (owner == 2'd1)),
		.wr_data(DDRAM_DOUT),
		.wr_full(f_full), .wr_almost_full(),
		.rd_clk(clk_m1), .rd_reset(reset),
		.rd_en(!f_empty), .rd_data(f_dout), .rd_empty(f_empty)
	);
	assign m1_dout = f_dout;
	assign m1_dout_ready = !f_empty;
	wire _uf = f_full;

	wire acc = !DDRAM_BUSY;
	wire m0_cmd = m0_rd | m0_we;
	wire m2_cmd = m2_rd | m2_we;
	wire m2_req = m2_want | m2_cmd;
	wire m1_req = m1w2 | m1_rd | m1_we;

	// Gap: m2 not driving a command this cycle and no write lock.
	wire m2_gap = !m2_rd && !m2_we && !wr_lock;

	always @(posedge clk) begin
		if (rst) begin
			owner   <= 2'd0;
			wr_left <= 8'd0;
			rd_left <= 8'd0;
			qcnt    <= QMAX;
			m0_pri  <= 1'b0;
			m0_rsp  <= 1'b0;
		end else begin
			// Clear m0_rsp on the response beat even if owner already moved
			// (guards the NBA race where owner<=m2 same cycle as m0_rsp<=1).
			if (m0_rsp && DDRAM_DOUT_READY)
				m0_rsp <= 1'b0;

			// ---- Write-burst lock FSM + quantum + owner ----
			// Capture BURSTCNT on first accepted WE only; never reload while WE stays high.
			// Clear lock when WE drops or last beat accepted. Stale wr_left must not
			// survive into RD/SETUP gaps (that blocked m0 quantum yield).
			if (acc && sel_we) begin
`ifndef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
				if (owner == 2'd2 && (m0_cmd || m0_pri)) begin
					if (qcnt <= 8'd1) begin m0_pri <= 1'b1; qcnt <= QMAX;
					end else qcnt <= qcnt - 8'd1;
				end
`endif
				// Half-duplex masters (ddr_frame_dma): a write accept means the
				// preceding read response window is done. Scrub stale rd_left so
				// xact_lock cannot stick at rd_left==1 across WR/SETUP gaps.
				if (owner == 2'd2 || owner == 2'd0)
					rd_left <= 8'd0;
				if (!wr_lock) begin
					// First beat of a write transaction
					if (owner == 2'd0 && m0_pri) begin m0_pri <= 1'b0; qcnt <= QMAX; end
					if (sel_bc > 8'd1)
						wr_left <= sel_bc - 8'd1;
					else begin
						wr_left <= 8'd0;
`ifndef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
						// CWE path: continuous single-beat WE never drops to create a
						// gap. Yield immediately after an accepted bc==1 when m0_pri.
						if (owner == 2'd2 && m0_pri) begin
							owner  <= 2'd0;
							m0_pri <= 1'b0;
							qcnt   <= QMAX;
						end
`endif
					end
				end else if (wr_left == 8'd1) begin
					wr_left <= 8'd0;
				end else begin
					wr_left <= wr_left - 8'd1;
				end
			end else if (wr_lock && !sel_we) begin
				// Master dropped WE — transaction over (or idle gap).
				wr_left <= 8'd0;
			end else if (acc && sel_rd && !rd_lock &&
			            // One-shot m0 slice: do not start a new m0 RD when DMA
			            // is waiting to reclaim the bus. Prevents NBA race:
			            //   last m0 DOUT → rd_left/m0_rsp clear
			            //   same cycle owner→m2 AND m0 re-accept rd_left≤1
			            // which stuck G1 as own=2 rdl=1 prdl=0 rspl=8.
			            !(owner == 2'd0 && m2_req)) begin
				// Do not accept a new RD while responses are still outstanding.
`ifndef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
				if (owner == 2'd2 && (m0_cmd || m0_pri)) begin
					if (qcnt <= 8'd1) begin m0_pri <= 1'b1; qcnt <= QMAX;
					end else qcnt <= qcnt - 8'd1;
				end
`endif
				rd_left <= (sel_bc == 8'd0) ? 8'd1 : sel_bc;
				if (owner == 2'd0) begin
					m0_rsp <= 1'b1;
					if (m0_pri) begin m0_pri <= 1'b0; qcnt <= QMAX; end
				end
			end

			// Always count DOUT_READY under rd_lock. Do NOT gate on !sel_rd:
			// present holds m0_rd, which previously skipped the last beat and
			// froze rd_left==1 (xact_lock forever).
			if (rd_lock && DDRAM_DOUT_READY &&
			    (owner == 2'd2 || owner == 2'd0)) begin
				if (rd_left == 8'd1)
					rd_left <= 8'd0;
				else
					rd_left <= rd_left - 8'd1;
			end

			// ---- Owner arbitration ----
			// Never rearb mid-write (wr_lock) or mid-m0-read-response.
			// Never rearb while the current owner still asserts RD/WE (command lock).
`ifdef DDR_ARB3_FAULT_M2_STICKY_NO_QUANTUM
			if (!xact_lock && !m0_rsp) begin
				if (m2_req) owner <= 2'd2;
				else if (m1_req) owner <= 2'd1;
				else owner <= 2'd0;
			end
`else
			// Product policy:
			//  - m2 (DMA) is default owner while m2_req
			//  - after Q accepted m2 beats, m0_pri one-shot yields at xact boundary
			//  - m0 may complete one outstanding xact (rd_lock/wr_lock/m0_rsp), then
			//    bus returns to m2 if m2_req — present cannot hog via held m0_rd
			if (owner == 2'd2) begin
				// Only yield inside DMA ST_YIELD (or when m2 fully idle).
				// Prevents mid-RD_DATA steal when rd_left undercounts.
				if (!xact_lock && !(m2_rd || m2_we) && (m2_yield_window || !m2_req)) begin
					if (m0_pri) begin
						owner  <= 2'd0;
						m0_pri <= 1'b0; // one-shot
						qcnt   <= QMAX;
					end else if (!m2_req && m1_req)
						owner <= 2'd1;
				end
			end else if (owner == 2'd0) begin
				// After m0 xact retires, return to DMA even if present still
				// holds m0_rd (one-shot slice). Block only while xact/rsp live.
				if (!xact_lock && !m0_rsp) begin
					if (m2_req) begin
						owner <= 2'd2;
						qcnt  <= QMAX;
					end else if (m1_req)
						owner <= 2'd1;
				end
			end else begin // owner m1
				if (!m1_req && !xact_lock) begin
					if (m2_req) owner <= 2'd2;
					else owner <= 2'd0;
				end
			end
`endif
		end
	end
endmodule
`default_nettype wire
