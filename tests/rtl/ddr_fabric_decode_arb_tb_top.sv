// Dual-DUT top: priority arb (product) + naive sticky-DPB (negative) + ENABLE=0.
`default_nettype none

module ddr_fabric_decode_arb_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        m_p_rd,
	input  wire  [7:0] m_p_burstcnt,
	input  wire [28:0] m_p_addr,
	input  wire        m_dpb_want,
	input  wire        m_dpb_rd,
	input  wire        m_dpb_we,
	input  wire  [7:0] m_dpb_burstcnt,
	input  wire [28:0] m_dpb_addr,
	input  wire [63:0] m_dpb_din,
	input  wire        m_bs_want,
	input  wire        m_bs_rd,
	input  wire  [7:0] m_bs_burstcnt,
	input  wire [28:0] m_bs_addr,
	output wire        prio_m_p_busy,
	output wire        prio_m_p_dout_ready,
	output wire [63:0] prio_m_p_dout,
	output wire        prio_m_dpb_busy,
	output wire        prio_DDRAM_RD,
	output wire        prio_DDRAM_WE,
	output wire [28:0] prio_DDRAM_ADDR,
	output wire  [1:0] prio_grant_oh,
	output wire  [7:0] prio_wc_block,
	output wire        naive_m_p_busy,
	output wire        naive_m_p_dout_ready,
	output wire        naive_DDRAM_RD,
	output wire        naive_DDRAM_WE,
	output wire [28:0] naive_DDRAM_ADDR,
	output wire        off_m_p_busy,
	output wire        off_m_p_dout_ready,
	output wire        off_DDRAM_RD,
	output wire        off_DDRAM_WE,
	output wire [28:0] off_DDRAM_ADDR,
	output wire        off_m_dpb_busy
);
	reg prio_ready, naive_ready, off_ready;
	reg [63:0] prio_dout, naive_dout, off_dout;
	reg [8:0] prio_left, naive_left, off_left;

	wire [7:0] prio_bcnt, naive_bcnt, off_bcnt;
	wire [28:0] prio_a, naive_a, off_a;
	wire prio_rd, naive_rd, off_rd;
	wire prio_we, naive_we, off_we;
	wire [63:0] prio_din, naive_din, off_din;
	wire [7:0] prio_be, naive_be, off_be;

	ddr_fabric_decode_arb #(
		.ENABLE_FABRIC_DECODE(1'b1),
		.MAX_LOPRI_BURST(16)
	) u_prio (
		.clk(clk), .reset(reset),
		.m_p_busy(prio_m_p_busy),
		.m_p_burstcnt(m_p_burstcnt),
		.m_p_addr(m_p_addr),
		.m_p_dout(prio_m_p_dout),
		.m_p_dout_ready(prio_m_p_dout_ready),
		.m_p_rd(m_p_rd),
		.m_p_din(64'd0),
		.m_p_be(8'h00),
		.m_p_we(1'b0),
		.m_dpb_want(m_dpb_want),
		.m_dpb_busy(prio_m_dpb_busy),
		.m_dpb_burstcnt(m_dpb_burstcnt),
		.m_dpb_addr(m_dpb_addr),
		.m_dpb_dout(),
		.m_dpb_dout_ready(),
		.m_dpb_rd(m_dpb_rd),
		.m_dpb_din(m_dpb_din),
		.m_dpb_be(8'hFF),
		.m_dpb_we(m_dpb_we),
		.m_bs_want(m_bs_want),
		.m_bs_busy(),
		.m_bs_burstcnt(m_bs_burstcnt),
		.m_bs_addr(m_bs_addr),
		.m_bs_dout(),
		.m_bs_dout_ready(),
		.m_bs_rd(m_bs_rd),
		.m_bs_din(64'd0),
		.m_bs_be(8'h00),
		.m_bs_we(1'b0),
		.DDRAM_BUSY(1'b0),
		.DDRAM_BURSTCNT(prio_bcnt),
		.DDRAM_ADDR(prio_a),
		.DDRAM_DOUT(prio_dout),
		.DDRAM_DOUT_READY(prio_ready),
		.DDRAM_RD(prio_rd),
		.DDRAM_DIN(prio_din),
		.DDRAM_BE(prio_be),
		.DDRAM_WE(prio_we),
		.grant_oh(prio_grant_oh),
		.wc_present_block_beats(prio_wc_block)
	);

	ddr_fabric_decode_arb_naive_sticky_dpb u_naive (
		.clk(clk), .reset(reset),
		.m_p_busy(naive_m_p_busy),
		.m_p_burstcnt(m_p_burstcnt),
		.m_p_addr(m_p_addr),
		.m_p_dout(),
		.m_p_dout_ready(naive_m_p_dout_ready),
		.m_p_rd(m_p_rd),
		.m_p_din(64'd0),
		.m_p_be(8'h00),
		.m_p_we(1'b0),
		.m_dpb_want(m_dpb_want),
		.m_dpb_busy(),
		.m_dpb_burstcnt(m_dpb_burstcnt),
		.m_dpb_addr(m_dpb_addr),
		.m_dpb_dout(),
		.m_dpb_dout_ready(),
		.m_dpb_rd(m_dpb_rd),
		.m_dpb_din(m_dpb_din),
		.m_dpb_be(8'hFF),
		.m_dpb_we(m_dpb_we),
		.m_bs_want(1'b0),
		.m_bs_busy(),
		.m_bs_burstcnt(8'd1),
		.m_bs_addr(29'd0),
		.m_bs_dout(),
		.m_bs_dout_ready(),
		.m_bs_rd(1'b0),
		.m_bs_din(64'd0),
		.m_bs_be(8'h00),
		.m_bs_we(1'b0),
		.DDRAM_BUSY(1'b0),
		.DDRAM_BURSTCNT(naive_bcnt),
		.DDRAM_ADDR(naive_a),
		.DDRAM_DOUT(naive_dout),
		.DDRAM_DOUT_READY(naive_ready),
		.DDRAM_RD(naive_rd),
		.DDRAM_DIN(naive_din),
		.DDRAM_BE(naive_be),
		.DDRAM_WE(naive_we)
	);

	ddr_fabric_decode_arb #(
		.ENABLE_FABRIC_DECODE(1'b0),
		.MAX_LOPRI_BURST(16)
	) u_off (
		.clk(clk), .reset(reset),
		.m_p_busy(off_m_p_busy),
		.m_p_burstcnt(m_p_burstcnt),
		.m_p_addr(m_p_addr),
		.m_p_dout(),
		.m_p_dout_ready(off_m_p_dout_ready),
		.m_p_rd(m_p_rd),
		.m_p_din(64'd0),
		.m_p_be(8'h00),
		.m_p_we(1'b0),
		.m_dpb_want(1'b1),
		.m_dpb_busy(off_m_dpb_busy),
		.m_dpb_burstcnt(8'd16),
		.m_dpb_addr(29'h100),
		.m_dpb_dout(),
		.m_dpb_dout_ready(),
		.m_dpb_rd(1'b1),
		.m_dpb_din(64'hDEAD),
		.m_dpb_be(8'hFF),
		.m_dpb_we(1'b1),
		.m_bs_want(1'b1),
		.m_bs_busy(),
		.m_bs_burstcnt(8'd8),
		.m_bs_addr(29'h200),
		.m_bs_dout(),
		.m_bs_dout_ready(),
		.m_bs_rd(1'b1),
		.m_bs_din(64'd0),
		.m_bs_be(8'h00),
		.m_bs_we(1'b0),
		.DDRAM_BUSY(1'b0),
		.DDRAM_BURSTCNT(off_bcnt),
		.DDRAM_ADDR(off_a),
		.DDRAM_DOUT(off_dout),
		.DDRAM_DOUT_READY(off_ready),
		.DDRAM_RD(off_rd),
		.DDRAM_DIN(off_din),
		.DDRAM_BE(off_be),
		.DDRAM_WE(off_we),
		.grant_oh(),
		.wc_present_block_beats()
	);

	assign prio_DDRAM_RD = prio_rd;
	assign prio_DDRAM_WE = prio_we;
	assign prio_DDRAM_ADDR = prio_a;
	assign naive_DDRAM_RD = naive_rd;
	assign naive_DDRAM_WE = naive_we;
	assign naive_DDRAM_ADDR = naive_a;
	assign off_DDRAM_RD = off_rd;
	assign off_DDRAM_WE = off_we;
	assign off_DDRAM_ADDR = off_a;

	always @(posedge clk) begin
		if (reset) begin
			prio_ready <= 1'b0; naive_ready <= 1'b0; off_ready <= 1'b0;
			prio_dout <= 64'd0; naive_dout <= 64'd0; off_dout <= 64'd0;
			prio_left <= 9'd0; naive_left <= 9'd0; off_left <= 9'd0;
		end else begin
			if (prio_left != 9'd0) begin
				prio_ready <= 1'b1;
				prio_dout  <= {35'd0, prio_a};
				prio_left  <= prio_left - 9'd1;
			end else begin
				prio_ready <= 1'b0;
				if (prio_rd)
					prio_left <= {1'b0, prio_bcnt};
			end
			if (naive_left != 9'd0) begin
				naive_ready <= 1'b1;
				naive_dout  <= {35'd0, naive_a};
				naive_left  <= naive_left - 9'd1;
			end else begin
				naive_ready <= 1'b0;
				if (naive_rd)
					naive_left <= {1'b0, naive_bcnt};
			end
			if (off_left != 9'd0) begin
				off_ready <= 1'b1;
				off_dout  <= {35'd0, off_a};
				off_left  <= off_left - 9'd1;
			end else begin
				off_ready <= 1'b0;
				if (off_rd)
					off_left <= {1'b0, off_bcnt};
			end
		end
	end
endmodule

`default_nettype wire
