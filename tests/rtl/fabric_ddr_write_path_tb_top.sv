`default_nettype none
module fabric_ddr_write_path_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire [1:0]  bank_id,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire        busy,
	output wire        frame_done
);
	fabric_ddr_write_path #(
		.CODED_W(16), .CODED_H(16),
		.PHYS_BASE(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0000_2000),
		.DOORBELL_PHYS(32'h3018_3000),
		.WRITE_DRAIN_CYCLES(4),
		.USE_INTERNAL_PATTERN(1'b1)
	) dut (
		.clk(clk), .reset(reset),
		.start(start), .bank_id(bank_id),
		.ext_valid(1'b0), .ext_ready(), .ext_data(64'd0),
		.ext_frame_start(1'b0), .ext_bank_id(2'd0),
		.DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.busy(busy), .frame_done(frame_done),
		.dbg_seq(), .dbg_last_bank()
	);
endmodule
`default_nettype wire
