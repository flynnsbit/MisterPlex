// Concurrent path (b): arbiter3 m0 synthetic present-RD + m2 mem2mem.
// Small I420 geometry for unit speed; proves RD+WE on m2 while m0 contends.
`default_nettype none
module fabric_mem2mem_arb_conc_tb_top (
	input  wire        clk,
	input  wire        clk_m1,
	input  wire        reset,
	input  wire        start,
	input  wire        bank_sel,
	input  wire        m0_rd,
	input  wire [28:0] m0_addr_q,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire        m0_busy,
	output wire        m2_busy,
	output wire        m2_want,
	output wire        busy,
	output wire        frame_done,
	output wire [31:0] dbg_beats_moved,
	output wire        m0_dout_ready,
	output wire [63:0] m0_dout
);
	localparam [31:0] PHYS = 32'h3018_0000;
	localparam int STRIDE = 32'h0000_2000;
	localparam [31:0] DOORBELL = 32'h3018_1F00;
	localparam [31:0] STAGING = 32'h3060_1000;
	localparam int CW = 64;
	localparam int CH = 48;

	wire  [7:0] m2_burstcnt;
	wire [28:0] m2_addr;
	wire [63:0] m2_dout;
	wire        m2_dout_ready;
	wire        m2_rd;
	wire [63:0] m2_din;
	wire  [7:0] m2_be;
	wire        m2_we;
	wire  [3:0] dbg_state;
	wire        m1_busy;

	fabric_ddr_mem2mem_attach #(
		.CODED_W(CW),
		.CODED_H(CH),
		.PHYS_BASE(PHYS),
		.HPS_BANK_STRIDE_BYTES(STRIDE),
		.DOORBELL_PHYS(DOORBELL),
		.STAGING_PHYS(STAGING),
		.WRITE_DRAIN_CYCLES(4)
	) attach (
		.clk(clk),
		.reset(reset),
		.start(start),
		.bank_sel(bank_sel),
		.m2_want(m2_want),
		.m2_busy(m2_busy),
		.m2_burstcnt(m2_burstcnt),
		.m2_addr(m2_addr),
		.m2_dout(m2_dout),
		.m2_dout_ready(m2_dout_ready),
		.m2_rd(m2_rd),
		.m2_din(m2_din),
		.m2_be(m2_be),
		.m2_we(m2_we),
		.busy(busy),
		.frame_done(frame_done),
		.dbg_beats_moved(dbg_beats_moved),
		.dbg_state(dbg_state)
	);

	ddr_bus_arbiter3 #(
		.M2_OVER_M0(1'b1) // path (b) fill priority while m2_want
	) arb (
		.clk(clk),
		.clk_m1(clk_m1),
		.reset(reset),
		.m1_want(1'b0),
		.m2_want(m2_want),
		.m0_busy(m0_busy),
		.m0_burstcnt(8'd1),
		.m0_addr(m0_addr_q),
		.m0_dout(m0_dout),
		.m0_dout_ready(m0_dout_ready),
		.m0_rd(m0_rd),
		.m0_din(64'd0),
		.m0_be(8'hFF),
		.m0_we(1'b0),
		.m1_busy(m1_busy),
		.m1_burstcnt(8'd1),
		.m1_addr(29'd0),
		.m1_dout(),
		.m1_dout_ready(),
		.m1_rd(1'b0),
		.m1_din(64'd0),
		.m1_be(8'hFF),
		.m1_we(1'b0),
		.m2_busy(m2_busy),
		.m2_burstcnt(m2_burstcnt),
		.m2_addr(m2_addr),
		.m2_dout(m2_dout),
		.m2_dout_ready(m2_dout_ready),
		.m2_rd(m2_rd),
		.m2_din(m2_din),
		.m2_be(m2_be),
		.m2_we(m2_we),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE)
	);
endmodule
`default_nettype wire
