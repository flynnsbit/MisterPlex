// ddr_bus_arbiter4 — four-master f2sdram arbiter for present + stream + bulk + MC.
//
// NOT product-wired by default. Contract module for fabric H.264 DPB/MC client
// (w-nostub). Instantiate only behind an explicit ifdef when DPB lands.
//
// Masters (priority at idle re-arb, highest first):
//   m0 present/scanout — hard real-time; never underrun
//   m3 MC/DPB ref read — latency-critical scattered small reads
//   m2 bulk frame write / DMA / mailbox
//   m1 stream (async_fifo CDC path)
//
// Invariants:
//   1) No mid-burst revoke (wr_lock | rd_lock sticky until beats complete).
//   2) Max accepted BURSTCNT clamped to MAX_BURST (default 8) so scanout WC
//      wait is bounded: WC_m0_wait_beats <= MAX_BURST + 1 pipeline.
//   3) m3 quantum Q_MC accepted beats then yield-to-m0 at xact boundary when
//      m0_cmd pending (m0_pri one-shot).
//   4) m2 quantum Q_BULK same shape as arbiter3.
//
// Starvation bounds (beats of bus occupancy, excluding controller BUSY):
//   m0: WC = MAX_BURST (finish current non-m0 burst) + accept own cmd next gap
//   m3: WC = (other masters each take one quantum) + m0 one-shot slices
//       ≈ Q_BULK + MAX_BURST + m1 window; not hard-RT
//   m2/m1: best-effort under m0/m3 pressure
//
// M10K: m1 async_fifo ramstyle=MLAB → 0 (measured analogue arbiter3).
// Quartus 17.0: no SV-2012 default port values.

`default_nettype none

module ddr_bus_arbiter4 #(
	parameter int MAX_BURST     = 8,
	parameter int M2_QUANTUM    = 8,
	parameter int M3_QUANTUM    = 4
) (
	input  wire        clk,
	input  wire        clk_m1,
	input  wire        reset,
	input  wire        m1_want,
	input  wire        m2_want,
	input  wire        m2_yield_window,
	input  wire        m3_want,
	// m0 present
	output wire        m0_busy,
	input  wire  [7:0] m0_burstcnt,
	input  wire [28:0] m0_addr,
	output wire [63:0] m0_dout,
	output wire        m0_dout_ready,
	input  wire        m0_rd,
	input  wire [63:0] m0_din,
	input  wire  [7:0] m0_be,
	input  wire        m0_we,
	// m1 stream
	output wire        m1_busy,
	input  wire  [7:0] m1_burstcnt,
	input  wire [28:0] m1_addr,
	output wire [63:0] m1_dout,
	output wire        m1_dout_ready,
	input  wire        m1_rd,
	input  wire [63:0] m1_din,
	input  wire  [7:0] m1_be,
	input  wire        m1_we,
	// m2 bulk
	output wire        m2_busy,
	input  wire  [7:0] m2_burstcnt,
	input  wire [28:0] m2_addr,
	output wire [63:0] m2_dout,
	output wire        m2_dout_ready,
	input  wire        m2_rd,
	input  wire [63:0] m2_din,
	input  wire  [7:0] m2_be,
	input  wire        m2_we,
	// m3 MC/DPB
	output wire        m3_busy,
	input  wire  [7:0] m3_burstcnt,
	input  wire [28:0] m3_addr,
	output wire [63:0] m3_dout,
	output wire        m3_dout_ready,
	input  wire        m3_rd,
	input  wire [63:0] m3_din,
	input  wire  [7:0] m3_be,
	input  wire        m3_we,
	// shared DDR
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire  [1:0] grant_owner // 0=m0 1=m1 2=m2 3=m3
);
	reg reset_s1, reset_s2;
	always @(posedge clk or posedge reset) begin
		if (reset) begin reset_s1 <= 1'b1; reset_s2 <= 1'b1;
		end else begin reset_s1 <= 1'b0; reset_s2 <= reset_s1; end
	end
	wire rst = reset_s2;

	localparam [7:0] BMAX = (MAX_BURST < 1) ? 8'd1 :
	                        (MAX_BURST > 255) ? 8'd255 : 8'(MAX_BURST);
	localparam [7:0] Q2 = (M2_QUANTUM < 1) ? 8'd1 :
	                      (M2_QUANTUM > 255) ? 8'd255 : 8'(M2_QUANTUM);
	localparam [7:0] Q3 = (M3_QUANTUM < 1) ? 8'd1 :
	                      (M3_QUANTUM > 255) ? 8'd255 : 8'(M3_QUANTUM);

	function automatic [7:0] clamp_bc(input [7:0] bc);
		begin
			if (bc == 8'd0) clamp_bc = 8'd1;
			else if (bc > BMAX) clamp_bc = BMAX;
			else clamp_bc = bc;
		end
	endfunction

	reg [1:0] owner;
	assign grant_owner = owner;
	reg [7:0] wr_left, rd_left;
	reg [7:0] q2, q3;
	reg       m0_pri;
	reg       m0_rsp;

	wire wr_lock = (wr_left != 8'd0);
	wire rd_lock = (rd_left != 8'd0);
	wire xact_lock = wr_lock | rd_lock;

	wire use1 = (owner == 2'd1);
	wire use2 = (owner == 2'd2);
	wire use3 = (owner == 2'd3);

	wire [7:0] raw_bc = use1 ? m1_burstcnt : use2 ? m2_burstcnt :
	                    use3 ? m3_burstcnt : m0_burstcnt;
	wire [7:0] sel_bc = clamp_bc(raw_bc);
	wire       sel_rd = use1 ? m1_rd : use2 ? m2_rd : use3 ? m3_rd : m0_rd;
	wire       sel_we = use1 ? m1_we : use2 ? m2_we : use3 ? m3_we : m0_we;
	wire [28:0] sel_ad = use1 ? m1_addr : use2 ? m2_addr : use3 ? m3_addr : m0_addr;
	wire [63:0] sel_di = use1 ? m1_din  : use2 ? m2_din  : use3 ? m3_din  : m0_din;
	wire [7:0]  sel_be = use1 ? m1_be   : use2 ? m2_be   : use3 ? m3_be   : m0_be;

	assign m0_busy = DDRAM_BUSY | (owner != 2'd0);
	assign m0_dout = DDRAM_DOUT;
	assign m0_dout_ready = DDRAM_DOUT_READY & (owner == 2'd0);

	assign m2_busy = DDRAM_BUSY | (owner != 2'd2);
	assign m2_dout = DDRAM_DOUT;
	assign m2_dout_ready = DDRAM_DOUT_READY & (owner == 2'd2);

	assign m3_busy = DDRAM_BUSY | (owner != 2'd3);
	assign m3_dout = DDRAM_DOUT;
	assign m3_dout_ready = DDRAM_DOUT_READY & (owner == 2'd3);

	// m1 busy CDC (same as arbiter3)
	reg m1w1, m1w2;
	always @(posedge clk) begin
		if (rst) begin m1w1 <= 0; m1w2 <= 0;
		end else begin m1w1 <= m1_want; m1w2 <= m1w1; end
	end
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

	assign DDRAM_BURSTCNT = sel_bc;
	assign DDRAM_ADDR     = sel_ad;
	assign DDRAM_RD       = sel_rd;
	assign DDRAM_DIN      = sel_di;
	assign DDRAM_BE       = sel_be;
	assign DDRAM_WE       = sel_we;

	wire acc = !DDRAM_BUSY;
	wire m0_cmd = m0_rd | m0_we;
	wire m2_cmd = m2_rd | m2_we;
	wire m3_cmd = m3_rd | m3_we;
	wire m2_req = m2_want | m2_cmd;
	wire m3_req = m3_want | m3_cmd;
	wire m1_req = m1w2 | m1_rd | m1_we;

	always @(posedge clk) begin
		if (rst) begin
			owner   <= 2'd0;
			wr_left <= 8'd0;
			rd_left <= 8'd0;
			q2      <= Q2;
			q3      <= Q3;
			m0_pri  <= 1'b0;
			m0_rsp  <= 1'b0;
		end else begin
			if (m0_rsp && DDRAM_DOUT_READY)
				m0_rsp <= 1'b0;

			// Accept path: quantum accounting for m2/m3 when m0 waiting
			if (acc && sel_we) begin
				if (owner == 2'd2 && (m0_cmd || m0_pri)) begin
					if (q2 <= 8'd1) begin m0_pri <= 1'b1; q2 <= Q2; end
					else q2 <= q2 - 8'd1;
				end
				if (owner == 2'd3 && (m0_cmd || m0_pri)) begin
					if (q3 <= 8'd1) begin m0_pri <= 1'b1; q3 <= Q3; end
					else q3 <= q3 - 8'd1;
				end
				if (owner == 2'd2 || owner == 2'd0 || owner == 2'd3)
					rd_left <= 8'd0;
				if (!wr_lock) begin
					if (owner == 2'd0 && m0_pri) begin m0_pri <= 1'b0; q2 <= Q2; q3 <= Q3; end
					if (sel_bc > 8'd1)
						wr_left <= sel_bc - 8'd1;
					else begin
						wr_left <= 8'd0;
						if ((owner == 2'd2 || owner == 2'd3) && m0_pri) begin
							owner  <= 2'd0;
							m0_pri <= 1'b0;
							q2 <= Q2; q3 <= Q3;
						end
					end
				end else if (wr_left == 8'd1)
					wr_left <= 8'd0;
				else
					wr_left <= wr_left - 8'd1;
			end else if (wr_lock && !sel_we) begin
				wr_left <= 8'd0;
			end else if (acc && sel_rd && !rd_lock &&
			            !(owner == 2'd0 && (m2_req || m3_req))) begin
				if (owner == 2'd2 && (m0_cmd || m0_pri)) begin
					if (q2 <= 8'd1) begin m0_pri <= 1'b1; q2 <= Q2; end
					else q2 <= q2 - 8'd1;
				end
				if (owner == 2'd3 && (m0_cmd || m0_pri)) begin
					if (q3 <= 8'd1) begin m0_pri <= 1'b1; q3 <= Q3; end
					else q3 <= q3 - 8'd1;
				end
				rd_left <= sel_bc;
				if (owner == 2'd0) begin
					m0_rsp <= 1'b1;
					if (m0_pri) begin m0_pri <= 1'b0; q2 <= Q2; q3 <= Q3; end
				end
			end

			if (rd_lock && DDRAM_DOUT_READY &&
			    (owner == 2'd2 || owner == 2'd0 || owner == 2'd3)) begin
				if (rd_left == 8'd1)
					rd_left <= 8'd0;
				else
					rd_left <= rd_left - 8'd1;
			end

			// Owner policy — m0_pri one-shot steals at xact boundary even if
			// m2/m3 keep RD/WE asserted (back-to-back MC). Never mid-burst.
			if (owner == 2'd3) begin
				if (!xact_lock) begin
					if (m0_pri) begin
						owner  <= 2'd0;
						m0_pri <= 1'b0;
						q3     <= Q3;
					end else if (!(m3_rd || m3_we)) begin
						if (m0_cmd) begin
							owner <= 2'd0;
						end else if (!m3_req) begin
							if (m2_req) owner <= 2'd2;
							else if (m1_req) owner <= 2'd1;
							else owner <= 2'd0;
						end
					end
				end
			end else if (owner == 2'd2) begin
				if (!xact_lock) begin
					if (m0_pri) begin
						owner  <= 2'd0;
						m0_pri <= 1'b0;
						q2     <= Q2;
					end else if (!(m2_rd || m2_we) && (m2_yield_window || !m2_req)) begin
						if (m0_cmd) owner <= 2'd0;
						else if (m3_req) owner <= 2'd3;
						else if (!m2_req && m1_req) owner <= 2'd1;
					end
				end
			end else if (owner == 2'd0) begin
				if (!xact_lock && !m0_rsp) begin
					// After m0 one-shot, prefer MC then bulk
					if (m3_req) begin owner <= 2'd3; q3 <= Q3; end
					else if (m2_req) begin owner <= 2'd2; q2 <= Q2; end
					else if (m1_req) owner <= 2'd1;
				end
			end else begin // m1
				if (!m1_req && !xact_lock) begin
					if (m0_cmd) owner <= 2'd0;
					else if (m3_req) owner <= 2'd3;
					else if (m2_req) owner <= 2'd2;
					else owner <= 2'd0;
				end
			end
		end
	end
endmodule

`default_nettype wire
