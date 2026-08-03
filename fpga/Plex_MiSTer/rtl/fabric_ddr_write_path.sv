// fabric_ddr_write_path — pattern (or external) source → fabric_ddr_writer.
// Single start/bank pulse interface for idle / bring-up without ARM pixels.
// Macro FABRIC_DDR_WRITER default OFF.
//
`default_nettype none

module fabric_ddr_write_path #(
	parameter int CODED_W = 1280,
	parameter int CODED_H = 720,
	parameter [31:0] PHYS_BASE = 32'h3018_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 32'h0018_0000,
	parameter [31:0] DOORBELL_PHYS = 32'h3047_F000,
	parameter int WRITE_DRAIN_CYCLES = 16,
	parameter bit USE_INTERNAL_PATTERN = 1'b1
)(
	input  wire        clk,
	input  wire        reset,

	// Pulse to paint one I420 frame into bank_id via internal pattern source.
	input  wire        start,
	input  wire [1:0]  bank_id,

	// Optional external source (when USE_INTERNAL_PATTERN=0)
	input  wire        ext_valid,
	output wire        ext_ready,
	input  wire [63:0] ext_data,
	input  wire        ext_frame_start,
	input  wire [1:0]  ext_bank_id,

	// DDRAM master
	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	output wire        busy,
	output wire        frame_done,
	output wire [28:0] dbg_seq,
	output wire [1:0]  dbg_last_bank
);

	wire        p_valid, p_ready, p_sof, p_busy, p_done;
	wire [63:0] p_data;
	wire [1:0]  p_bank;

	wire        s_valid = USE_INTERNAL_PATTERN ? p_valid : ext_valid;
	wire [63:0] s_data  = USE_INTERNAL_PATTERN ? p_data  : ext_data;
	wire        s_sof   = USE_INTERNAL_PATTERN ? p_sof   : ext_frame_start;
	wire [1:0]  s_bank  = USE_INTERNAL_PATTERN ? p_bank  : ext_bank_id;
	wire        s_ready;

	assign ext_ready = USE_INTERNAL_PATTERN ? 1'b0 : s_ready;
	assign p_ready   = USE_INTERNAL_PATTERN ? s_ready : 1'b0;

	generate
		if (USE_INTERNAL_PATTERN) begin : g_pat
			fabric_i420_pattern_src #(
				.CODED_W(CODED_W),
				.CODED_H(CODED_H)
			) pattern (
				.clk(clk),
				.reset(reset),
				.start(start),
				.bank_id(bank_id),
				.src_valid(p_valid),
				.src_ready(p_ready),
				.src_data(p_data),
				.src_frame_start(p_sof),
				.src_bank_id(p_bank),
				.busy(p_busy),
				.done_pulse(p_done)
			);
		end else begin : g_nopat
			assign p_valid = 1'b0;
			assign p_data  = 64'd0;
			assign p_sof   = 1'b0;
			assign p_bank  = 2'd0;
			assign p_busy  = 1'b0;
			assign p_done  = 1'b0;
			wire _u = start ^ bank_id[0] ^ bank_id[1];
		end
	endgenerate

	wire [2:0] dbg_state_unused;
	fabric_ddr_writer #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(HPS_BANK_STRIDE_BYTES),
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.WRITE_DRAIN_CYCLES(WRITE_DRAIN_CYCLES)
	) writer (
		.clk(clk),
		.reset(reset),
		.src_valid(s_valid),
		.src_ready(s_ready),
		.src_data(s_data),
		.src_frame_start(s_sof),
		.src_bank_id(s_bank),
		.DDRAM_CLK(DDRAM_CLK),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.busy(busy),
		.frame_done(frame_done),
		.dbg_seq(dbg_seq),
		.dbg_last_bank(dbg_last_bank),
		.dbg_state(dbg_state_unused)
	);

endmodule

`default_nettype wire
