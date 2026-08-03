// fabric_ddr_attach — pattern/ext source → fabric_ddr_writer → arbiter3 m2 port.
//
// FABRIC_DDR_WRITER default OFF. Instantiates only the write side; parent
// wires m2_* into ddr_bus_arbiter3 when enabling the macro.
//
// m2_want is level-high while the writer is busy (including drain/doorbell).
//
`default_nettype none

module fabric_ddr_attach #(
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

	input  wire        start,
	input  wire [1:0]  bank_id,

	input  wire        ext_valid,
	output wire        ext_ready,
	input  wire [63:0] ext_data,
	input  wire        ext_frame_start,
	input  wire [1:0]  ext_bank_id,

	// Arbiter m2 master port (clk_ddr)
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
	output wire [28:0] dbg_seq,
	output wire [1:0]  dbg_last_bank
);
	wire path_busy;
	fabric_ddr_write_path #(
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(HPS_BANK_STRIDE_BYTES),
		.DOORBELL_PHYS(DOORBELL_PHYS),
		.WRITE_DRAIN_CYCLES(WRITE_DRAIN_CYCLES),
		.USE_INTERNAL_PATTERN(USE_INTERNAL_PATTERN)
	) path (
		.clk(clk),
		.reset(reset),
		.start(start),
		.bank_id(bank_id),
		.ext_valid(ext_valid),
		.ext_ready(ext_ready),
		.ext_data(ext_data),
		.ext_frame_start(ext_frame_start),
		.ext_bank_id(ext_bank_id),
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
		.busy(path_busy),
		.frame_done(frame_done),
		.dbg_seq(dbg_seq),
		.dbg_last_bank(dbg_last_bank)
	);

	assign busy    = path_busy;
	assign m2_want = path_busy;

endmodule

`default_nettype wire
