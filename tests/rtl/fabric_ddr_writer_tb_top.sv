// Top: fabric_ddr_writer + optional fabric_i420_pattern_src (muxed by use_pattern).
`default_nettype none

module fabric_ddr_writer_tb_top (
	input  wire        clk,
	input  wire        reset,
	// Manual source (use_pattern=0)
	input  wire        src_valid,
	output wire        src_ready,
	input  wire [63:0] src_data,
	input  wire        src_frame_start,
	input  wire [1:0]  src_bank_id,
	// Pattern source control (use_pattern=1)
	input  wire        use_pattern,
	input  wire        pattern_start,
	input  wire [1:0]  pattern_bank_id,
	output wire        pattern_busy,
	output wire        pattern_done,
	// DDRAM
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
	output wire [1:0]  dbg_last_bank,
	output wire [2:0]  dbg_state
);

	// 16x16 I420=384B. Stride 0x2000; doorbell = base+2*stride-0x1000 = 0x30183000.
	localparam [31:0] PHYS = 32'h3018_0000;
	localparam int STRIDE = 32'h0000_2000;
	localparam [31:0] DOORBELL = 32'h3018_3000;

	wire        p_valid, p_ready, p_sof;
	wire [63:0] p_data;
	wire [1:0]  p_bank;
	wire        w_valid = use_pattern ? p_valid : src_valid;
	wire [63:0] w_data  = use_pattern ? p_data  : src_data;
	wire        w_sof   = use_pattern ? p_sof   : src_frame_start;
	wire [1:0]  w_bank  = use_pattern ? p_bank  : src_bank_id;
	wire        w_ready;
	assign src_ready = use_pattern ? 1'b0 : w_ready;
	assign p_ready   = use_pattern ? w_ready : 1'b0;

	fabric_i420_pattern_src #(
		.CODED_W(16),
		.CODED_H(16)
	) pattern (
		.clk(clk),
		.reset(reset),
		.start(pattern_start && use_pattern),
		.bank_id(pattern_bank_id),
		.src_valid(p_valid),
		.src_ready(p_ready),
		.src_data(p_data),
		.src_frame_start(p_sof),
		.src_bank_id(p_bank),
		.busy(pattern_busy),
		.done_pulse(pattern_done)
	);

	fabric_ddr_writer #(
		.CODED_W(16),
		.CODED_H(16),
		.PHYS_BASE(PHYS),
		.HPS_BANK_STRIDE_BYTES(STRIDE),
		.DOORBELL_PHYS(DOORBELL),
		.NUM_BANKS(2),
		.WRITE_DRAIN_CYCLES(4),
		.DOORBELL_MAGIC(32'h504C584B),
		.DOORBELL_FORMAT_YUV420P(2'd1)
	) dut (
		.clk(clk),
		.reset(reset),
		.src_valid(w_valid),
		.src_ready(w_ready),
		.src_data(w_data),
		.src_frame_start(w_sof),
		.src_bank_id(w_bank),
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
