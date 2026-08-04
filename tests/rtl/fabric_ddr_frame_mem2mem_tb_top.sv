// Thin wrapper so Verilator emits Vfabric_ddr_frame_mem2mem_tb_top.
// Do NOT `include ddr_frame_layout_params.svh here — DUT already includes it
// (duplicate localparam is a Verilator hard error).
`default_nettype none

module fabric_ddr_frame_mem2mem_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        bank_sel,
	input  wire [31:0] staging_phys_rt,
	input  wire        staging_phys_use_rt,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_CLK,
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
	output wire  [3:0] dbg_state,
	output wire [31:0] dbg_beats_moved
);
	// Option-C 720p defaults (must match ddr_frame_layout_params.svh).
	fabric_ddr_frame_mem2mem #(
		.CODED_W(1280),
		.CODED_H(720),
		.PHYS_BASE(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0018_0000),
		.DOORBELL_PHYS(32'h3047_F000),
		.STAGING_PHYS(32'h3060_1000),
		.WRITE_DRAIN_CYCLES(16)
	) dut (
		.clk(clk),
		.reset(reset),
		.start(start),
		.bank_sel(bank_sel),
		.staging_phys_rt(staging_phys_rt),
		.staging_phys_use_rt(staging_phys_use_rt),
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
		.dbg_state(dbg_state),
		.dbg_beats_moved(dbg_beats_moved)
	);
endmodule
`default_nettype wire
