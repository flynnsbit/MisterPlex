// fabric_ddr_mem2mem_attach — path (b) mem2mem on arbiter3 m2 (RD+WE).
// Macro FABRIC_DDR_FRAME_MEM2MEM default OFF. Credit-free single-shot start
// (host owns bank free mask for v1; product attach can add fabric_bank_credit later).
`default_nettype none
module fabric_ddr_mem2mem_attach #(
	parameter int CODED_W = 1280,
	parameter int CODED_H = 720,
	parameter [31:0] PHYS_BASE = 32'h3018_0000,
	parameter int HPS_BANK_STRIDE_BYTES = 32'h0018_0000,
	parameter [31:0] DOORBELL_PHYS = 32'h3047_F000,
	parameter [31:0] STAGING_PHYS = 32'h3060_1000,
	parameter int WRITE_DRAIN_CYCLES = 16
)(
	input  wire        clk,
	input  wire        reset,
	input  wire        start,
	input  wire        bank_sel,
	output wire        m2_want,
	input  wire        m2_busy,
	output wire  [7:0] m2_burstcnt,
	output wire [28:0] m2_addr,
	input  wire [63:0] m2_dout,
	input  wire        m2_dout_ready,
	output wire        m2_rd,
	output wire [63:0] m2_din,
	output wire  [7:0] m2_be,
	output wire        m2_we,
	output wire        busy,
	output wire        frame_done,
	output wire [31:0] dbg_beats_moved,
	output wire  [3:0] dbg_state
);
	wire frame_done_i;
	wire busy_i;
	fabric_ddr_frame_mem2mem #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(HPS_BANK_STRIDE_BYTES),
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.STAGING_PHYS(STAGING_PHYS),
		.WRITE_DRAIN_CYCLES(WRITE_DRAIN_CYCLES)
	) u_m2m (
		.clk(clk),
		.reset(reset),
		.start(start),
		.bank_sel(bank_sel),
		.staging_phys_rt(32'd0),
		.staging_phys_use_rt(1'b0),
		.DDRAM_CLK(),
		.DDRAM_BUSY(m2_busy),
		.DDRAM_BURSTCNT(m2_burstcnt),
		.DDRAM_ADDR(m2_addr),
		.DDRAM_DOUT(m2_dout),
		.DDRAM_DOUT_READY(m2_dout_ready),
		.DDRAM_RD(m2_rd),
		.DDRAM_DIN(m2_din),
		.DDRAM_BE(m2_be),
		.DDRAM_WE(m2_we),
		.busy(busy_i),
		.frame_done(frame_done_i),
		.dbg_seq(),
		.dbg_last_bank(),
		.dbg_state(dbg_state),
		.dbg_beats_moved(dbg_beats_moved)
	);
	assign busy = busy_i;
	assign frame_done = frame_done_i;
	// Want bus while transferring (m2_rd|m2_we sticky via busy)
	assign m2_want = busy_i | m2_rd | m2_we;
endmodule
`default_nettype wire
