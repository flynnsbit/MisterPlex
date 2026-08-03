// PLXD init/heartbeat gate: after reset, with NO doorbell, the core must
// still publish PLXD at BANK_MAILBOX_PHYS so ARM can learn a free bank.
// Parent HW: 0x3007F128 stayed zero for 12s with daemon stopped.
`default_nettype none

module ddr_frame_store_plxd_init_tb (
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire        vsync_pulse,
	output wire        has_frame,
	output wire        swap_pending,
	output wire [15:0] frames_done,
	output wire [7:0]  debug_state,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire        DDRAM_WE
);
	wire DDRAM_CLK;
	wire [7:0] DDRAM_BE;
	wire [7:0] rd_r, rd_g, rd_b;
	wire [15:0] underrun_count;
	wire doorbell_ok;

	// Match main product defaults for the mailbox page under test.
	// DOORBELL stays product 0x300FF000; BANK is the MAIN absolute 0x3007F128
	// unless the module defaults already derive from DOORBELL (tip fix).
	ddr_frame_store #(
		.FRAME_W(80),
		.FRAME_H(48),
		.FRAME_STRIDE(80),
		.CODED_W(80),
		.CODED_H(48),
		.DISPLAY_W(64),
		.DISPLAY_H(40),
		.PRESENT_X(4),
		.PRESENT_Y(0),
		.LINE_COUNT(4),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(524288),
		.DOORBELL_PHYS(32'h300F_F000),
		// Explicit main-absolute PLXD slot (parent measured this word stays 0).
		.BANK_MAILBOX_PHYS(32'h3007_F128),
		.DDR_BURST_MAX(8),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1)
	) dut (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(7'd0),
		.rd_y(6'd0),
		.rd_active(1'b0),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.start_req(1'b0),
		.bank_sel(1'b0),
		.status_osd(16'd0),
		.input_cmd_valid(1'b0),
		.input_cmd(8'd0),
		.sdram_test_state(4'd0),
		.sdram_size_code(4'd0),
		.sdram_error_count(16'd0),
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
		.vsync_pulse(vsync_pulse),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(underrun_count),
		.frames_done(frames_done),
		.doorbell_ok(doorbell_ok),
		.debug_state(debug_state)
	);
endmodule
`default_nettype wire
