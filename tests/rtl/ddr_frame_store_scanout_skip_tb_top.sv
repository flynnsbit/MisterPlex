// Identity skip gate top for ddr_frame_store (post-present scanout).
// Reuses the same small geometry as scanout_sustained; parameters select product vs broken holds.
`default_nettype none

module ddr_frame_store_scanout_skip_tb #(
	parameter bit WANT_Y_LINE_ONLY = 1'b1,
	parameter bit PENDING_READY_STICKY_PREP = 1'b1,
	parameter bit PREP_SLOT_RECYCLE = 1'b1,
	parameter bit SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC = 1'b1,
	parameter int LINE_COUNT = 4
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire [6:0]  rd_x,
	input  wire [5:0]  rd_y,
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
	output wire        debug_sticky_prep,
	output wire        debug_prep_recycle,
	output wire        debug_holds_pending,
	output wire        debug_pending_ready,
	output wire        debug_disp_bank,
	output wire        debug_pending_bank,
	output wire [3:0]  debug_state_ddr,
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
		.LINE_COUNT(LINE_COUNT),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(65536),
		.DOORBELL_PHYS(32'h3001_F000),
		.MAILBOX_PHYS(32'h3001_F100),
		.INPUT_MAILBOX_PHYS(32'h3001_F108),
		.SDRAM_MAILBOX_PHYS(32'h3001_F110),
		.FRAME_MAILBOX_PHYS(32'h3001_F118),
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
		.geom_enable(1'b0),
		.rt_coded_w(11'd0),
		.rt_coded_h(11'd0),
		.rt_y_stride(12'd0),
		.rt_chroma_stride(11'd0),
		.rt_display_w(11'd0),
		.rt_display_h(11'd0),
		.rt_present_x(11'd0),
		.rt_present_y(11'd0),
		.rt_crop_left(11'd0),
		.rt_crop_top(11'd0),
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

	assign debug_sticky_prep = PENDING_READY_STICKY_PREP;
	assign debug_prep_recycle = PREP_SLOT_RECYCLE;
	assign debug_holds_pending = SWAP_REQ_HOLDS_PENDING_ACROSS_VSYNC;
	assign debug_pending_ready = dut.pending_ready_s2;
	assign debug_disp_bank = dut.disp_bank;
	assign debug_pending_bank = dut.pending_bank;
	assign debug_state_ddr = dut.state_ddr;
endmodule

`default_nettype wire
