// Top: ddr_bus_arbiter3 + fabric_ddr_attach (tiny 8x8 I420) for Verilator.
`default_nettype none

module ddr_bus_arbiter3_tb_top (
	input  wire        clk,
	input  wire        clk_m1,
	input  wire        reset,
	input  wire        start,
	input  wire [1:0]  bank_id,
	// m0 inject (optional scanout contention)
	input  wire        m0_rd,
	input  wire [28:0] m0_addr,
	// m1 inject
	input  wire        m1_want,
	input  wire        m1_rd,
	input  wire [28:0] m1_addr,
	// DDR model
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire        busy,
	output wire        frame_done,
	output wire        m2_want,
	output wire        m0_busy,
	output wire        m1_busy,
	output wire        m2_busy
);
	// 8x8 I420 = 96 B = 12 qwords. Stride 0x1000; doorbell base+2*stride-0x100.
	localparam [31:0] PHYS = 32'h3018_0000;
	localparam int STRIDE = 32'h0000_1000;
	localparam [31:0] DOORBELL = 32'h3018_1F00;

	wire        m2_want_w;
	wire  [7:0] m2_burstcnt;
	wire [28:0] m2_addr;
	wire [63:0] m2_dout;
	wire        m2_dout_ready;
	wire        m2_rd;
	wire [63:0] m2_din;
	wire  [7:0] m2_be;
	wire        m2_we;
	wire [28:0] dbg_seq;
	wire [1:0]  dbg_bank;

	fabric_ddr_attach #(
		.CODED_W(8),
		.CODED_H(8),
		.PHYS_BASE(PHYS),
		.HPS_BANK_STRIDE_BYTES(STRIDE),
		.DOORBELL_PHYS(DOORBELL),
		.WRITE_DRAIN_CYCLES(2),
		.USE_INTERNAL_PATTERN(1'b1)
	) attach (
		.clk(clk),
		.reset(reset),
		.start(start),
		.bank_id(bank_id),
		.ext_valid(1'b0),
		.ext_ready(),
		.ext_data(64'd0),
		.ext_frame_start(1'b0),
		.ext_bank_id(2'd0),
		.m2_want(m2_want_w),
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
		.dbg_seq(dbg_seq),
		.dbg_last_bank(dbg_bank)
	);

	assign m2_want = m2_want_w;

	wire [63:0] m0_dout;
	wire        m0_dout_ready;
	wire [63:0] m1_dout;
	wire        m1_dout_ready;

	ddr_bus_arbiter3 arb (
		.clk(clk),
		.clk_m1(clk_m1),
		.reset(reset),
		.m1_want(m1_want),
		.m2_want(m2_want_w),
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
