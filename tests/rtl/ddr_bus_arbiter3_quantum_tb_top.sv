// Pure ddr_bus_arbiter3 top for sustained m2 WE vs m0 RD quantum tests.
// No fabric attach — TB drives m0/m2 continuously past LINE_COUNT depth.
`default_nettype none

module ddr_bus_arbiter3_quantum_tb_top (
	input  wire        clk,
	input  wire        clk_m1,
	input  wire        reset,
	input  wire        m0_rd,
	input  wire [28:0] m0_addr,
	input  wire        m1_want,
	input  wire        m1_rd,
	input  wire [28:0] m1_addr,
	input  wire        m2_want,
	input  wire        m2_we,
	input  wire [28:0] m2_addr,
	input  wire [63:0] m2_din,
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
	output wire        m1_busy,
	output wire        m2_busy,
	output wire        m0_dout_ready,
	output wire        m2_dout_ready
);
	wire [63:0] m0_dout, m1_dout, m2_dout;
	wire        m1_dout_ready;

	ddr_bus_arbiter3 #(
		.M2_QUANTUM_BEATS(8)
	) arb (
		.clk(clk),
		.clk_m1(clk_m1),
		.reset(reset),
		.m1_want(m1_want),
		.m2_want(m2_want),
		.m0_busy(m0_busy),
		.m0_burstcnt(8'd1),
		.m0_addr(m0_addr),
		.m0_dout(m0_dout),
		.m0_dout_ready(m0_dout_ready),
		.m0_rd(m0_rd),
		.m0_din(64'd0),
		.m0_be(8'hFF),
		.m0_we(1'b0),
		.m1_busy(m1_busy),
		.m1_burstcnt(8'd1),
		.m1_addr(m1_addr),
		.m1_dout(m1_dout),
		.m1_dout_ready(m1_dout_ready),
		.m1_rd(m1_rd),
		.m1_din(64'd0),
		.m1_be(8'hFF),
		.m1_we(1'b0),
		.m2_busy(m2_busy),
		.m2_burstcnt(8'd1),
		.m2_addr(m2_addr),
		.m2_dout(m2_dout),
		.m2_dout_ready(m2_dout_ready),
		.m2_rd(1'b0),
		.m2_din(m2_din),
		.m2_be(8'hFF),
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
