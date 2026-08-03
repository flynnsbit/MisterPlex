// Top wrapper for fabric_ddr_writer Verilator TB.
// Tiny geometry for speed; bank stride must leave doorbell above bank1 end
// (same rule as product Option-C: doorbell = base + 2*stride - 0x1000).
`default_nettype none

module fabric_ddr_writer_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        src_valid,
	output wire        src_ready,
	input  wire [63:0] src_data,
	input  wire        src_frame_start,
	input  wire        src_bank,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire        busy,
	output wire        frame_done,
	output wire [28:0] dbg_seq,
	output wire        dbg_last_bank,
	output wire  [2:0] dbg_state
);

	// 16x16 I420 = 384 B. Stride 0x2000 leaves bank1 end at base+0x2000+384
	// and doorbell at base+0x3000 (base + 2*stride - 0x1000).
	fabric_ddr_writer #(
		.CODED_W(16),
		.CODED_H(16),
		.PHYS_BASE(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0000_2000),
		.DOORBELL_PHYS(32'h3018_3000),
		.WRITE_DRAIN_CYCLES(4),
		.DOORBELL_MAGIC(32'h504C584B),
		.DOORBELL_FORMAT_YUV420P(2'd1)
	) dut (
		.clk(clk),
		.reset(reset),
		.src_valid(src_valid),
		.src_ready(src_ready),
		.src_data(src_data),
		.src_frame_start(src_frame_start),
		.src_bank(src_bank),
		.DDRAM_CLK(),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(64'd0),
		.DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.busy(busy),
		.frame_done(frame_done),
		.dbg_seq(dbg_seq),
		.dbg_last_bank(dbg_last_bank),
		.dbg_state(dbg_state)
	);

endmodule

`default_nettype wire
