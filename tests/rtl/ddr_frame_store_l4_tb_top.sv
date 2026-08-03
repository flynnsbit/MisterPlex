// L4 720p ddr_frame_store reader TB (sim only).
// Geometry matches ddr_frame_layout_params 720p tier + present_core L4 FS_* bind.
// LINE_COUNT is the variable under test (8 vs 16 blackout margin).
`default_nettype none

module ddr_frame_store_l4_tb #(
	parameter int LINE_COUNT = 8,
	parameter int DDR_BURST_MAX = 64
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire [10:0] rd_x,
	input  wire [9:0]  rd_y,
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
	output wire        debug_sched_valid,
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

	// L4 layout (ddr_frame_layout_params.svh 720p tier)
	localparam int FRAME_W = 1280;
	localparam int FRAME_H = 720;
	localparam int CODED_W = 1280;
	localparam int CODED_H = 720;
	localparam int DISPLAY_W = 1280;
	localparam int DISPLAY_H = 720;
	localparam [31:0] PHYS_BASE = 32'h3018_0000;
	localparam int BANK_STRIDE = 32'h0018_0000;
	localparam [31:0] DOORBELL = 32'h3047_F000;
	// Mailboxes stay on the 480p control-plane addresses (not owned by this lane).
	localparam [31:0] MAILBOX = 32'h3007_F100;
	localparam [31:0] FRAME_MBOX = 32'h3007_F118;

	ddr_frame_store #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.FRAME_STRIDE(FRAME_W),
		.CODED_W(CODED_W),
		.CODED_H(CODED_H),
		.DISPLAY_W(DISPLAY_W),
		.DISPLAY_H(DISPLAY_H),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(0),
		.PRESENT_Y(0),
		.LINE_COUNT(LINE_COUNT),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(BANK_STRIDE),
		.DOORBELL_PHYS(DOORBELL),
		.MAILBOX_PHYS(MAILBOX),
		.INPUT_MAILBOX_PHYS(32'h3007_F108),
		.SDRAM_MAILBOX_PHYS(32'h3007_F110),
		.FRAME_MAILBOX_PHYS(FRAME_MBOX),
		.BANK_MAILBOX_PHYS(32'h3007_F128),
		.DDR_BURST_MAX(DDR_BURST_MAX),
		.IGNORE_STALE_DOORBELL_AFTER_RESET(1'b1),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1)
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

	assign debug_sched_valid = dut.sched_valid;
endmodule

`default_nettype wire
