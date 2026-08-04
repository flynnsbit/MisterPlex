// Tear-free bank-swap gate for ddr_frame_store at 720p-ratio geometry.
// Product: disp_bank commits only on vsync && !rd_active → mono-bank frames.
// FAULT_MID_FRAME_SWAP: commit during rd_active → checker must detect tear.
`default_nettype none

module ddr_frame_store_bank_swap_tear_tb #(
	parameter bit WANT_Y_LINE_ONLY = 1'b1,
	parameter bit PENDING_READY_STICKY_PREP = 1'b1,
	parameter bit PREP_SLOT_RECYCLE = 1'b1,
	parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1,
	parameter int LINE_COUNT = 8
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	// 720p-ratio scaled: FRAME 160x90, display 128x90 (see TB cpp constants)
	input  wire [7:0]  rd_x,
	input  wire [6:0]  rd_y,
	input  wire        rd_active,
	input  wire        start_req,
	input  wire        bank_sel,
	input  wire        vsync_pulse,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire        swap_pending,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
	output wire [7:0]  debug_state,
	output wire        debug_pending_ready,
	output wire        debug_disp_bank,
	output wire        debug_pending_bank,
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

	// Scaled 720p geometry (10x linear shrink of 1600x750 / 1280x720):
	//   Real: H_TOTAL=1600 V_TOTAL=750 V_ACTIVE=720 VBlank=30 @ 28.8 MHz
	//         line=55.56 us, vblank=1.667 ms, frame=41.667 ms
	//   TB:   coded 160x90, display 128x90 — ratios preserved; absolute
	//         cycle counts compressed so multi-frame sims finish quickly.
	ddr_frame_store #(
		.FRAME_W(160),
		.FRAME_H(90),
		.FRAME_STRIDE(160),
		.CODED_W(160),
		.CODED_H(90),
		.DISPLAY_W(128),
		.DISPLAY_H(90),
		.PRESENT_X(16),
		.PRESENT_Y(0),
		.LINE_COUNT(LINE_COUNT),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(131072),
		.DOORBELL_PHYS(32'h3003_F000),
		.MAILBOX_PHYS(32'h3003_F100),
		.INPUT_MAILBOX_PHYS(32'h3003_F108),
		.SDRAM_MAILBOX_PHYS(32'h3003_F110),
		.FRAME_MAILBOX_PHYS(32'h3003_F118),
		.BANK_MAILBOX_PHYS(32'h3003_F128),
		.DDR_BURST_MAX(8),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1),
		.WANT_Y_LINE_ONLY(WANT_Y_LINE_ONLY),
		.PENDING_READY_STICKY_PREP(PENDING_READY_STICKY_PREP),
		.PREP_SLOT_RECYCLE(PREP_SLOT_RECYCLE),
		.SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC(SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC)
	) dut (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(rd_x),
		.rd_y(rd_y),
		.rd_active(rd_active),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.start_req(start_req),
		.bank_sel(bank_sel),
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

	assign debug_pending_ready = dut.pending_ready_s2;
	assign debug_disp_bank = dut.disp_bank;
	assign debug_pending_bank = dut.pending_bank;
endmodule

`default_nettype wire
