// Product-like scanout freeze red-check for ddr_frame_store.
// Cases (shell builds twice):
//   BROKEN: WANT_Y_LINE_ONLY=1 + PENDING_READY_STICKY_PREP=0  (9eb1431a)
//   GOOD:   WANT_Y_LINE_ONLY=1 + PENDING_READY_STICKY_PREP=1  (product fix)
// No WANT_Y_FORCE_TOP.
`default_nettype none

module ddr_frame_store_scanout_freeze_tb #(
	parameter bit WANT_Y_LINE_ONLY = 1'b1,
	parameter bit PENDING_READY_STICKY_PREP = 1'b1,
	parameter bit PREP_SLOT_RECYCLE = 1'b1,
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
	output wire [5:0]  debug_want_y,
	output wire        debug_sticky_prep,
	output wire        debug_prep_recycle,
	output wire [3:0]  debug_y_valid_cur,
	output wire [3:0]  debug_y_valid_prep,
	output wire [3:0]  debug_c_valid_prep,
	output wire [5:0]  debug_y_line0,
	output wire [5:0]  debug_y_line1,
	output wire [5:0]  debug_y_line2,
	output wire [5:0]  debug_y_line3,
	output wire [3:0]  debug_y_bank_cur,
	output wire        debug_sched_valid,
	output wire        debug_pending_ready,
	output wire        debug_disp_buf,
	output wire        debug_disp_bank,
	output wire        debug_pending_bank,
	output wire [3:0]  debug_state_ddr,
	output wire        debug_need_y_prep,
	output wire        debug_need_y_cur,
	output wire        debug_pending_ready_c,
	output wire        debug_sched_for_pend,
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
		.PREP_SLOT_RECYCLE(PREP_SLOT_RECYCLE)
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

	assign debug_want_y = dut.want_y_sys[5:0];
	assign debug_sticky_prep = PENDING_READY_STICKY_PREP;
	assign debug_prep_recycle = PREP_SLOT_RECYCLE;
	assign debug_sched_valid = dut.sched_valid;
	assign debug_pending_ready = dut.pending_ready_s2;
	assign debug_disp_buf = dut.disp_buf;
	assign debug_disp_bank = dut.disp_bank;
	assign debug_pending_bank = dut.pending_bank;
	wire [3:0] yv0 = {dut.y_valid[3], dut.y_valid[2], dut.y_valid[1], dut.y_valid[0]};
	wire [3:0] yv1 = {dut.y_valid[7], dut.y_valid[6], dut.y_valid[5], dut.y_valid[4]};
	wire [3:0] cv0 = {dut.c_valid[3], dut.c_valid[2], dut.c_valid[1], dut.c_valid[0]};
	wire [3:0] cv1 = {dut.c_valid[7], dut.c_valid[6], dut.c_valid[5], dut.c_valid[4]};
	assign debug_y_valid_cur = dut.disp_buf ? yv1 : yv0;
	assign debug_y_valid_prep = dut.disp_buf ? yv0 : yv1;
	assign debug_c_valid_prep = dut.disp_buf ? cv0 : cv1;
	assign debug_y_line0 = dut.disp_buf ? dut.y_line[4][5:0] : dut.y_line[0][5:0];
	assign debug_y_line1 = dut.disp_buf ? dut.y_line[5][5:0] : dut.y_line[1][5:0];
	assign debug_y_line2 = dut.disp_buf ? dut.y_line[6][5:0] : dut.y_line[2][5:0];
	assign debug_y_line3 = dut.disp_buf ? dut.y_line[7][5:0] : dut.y_line[3][5:0];
	assign debug_y_bank_cur = dut.disp_buf
		? {dut.y_bank[7], dut.y_bank[6], dut.y_bank[5], dut.y_bank[4]}
		: {dut.y_bank[3], dut.y_bank[2], dut.y_bank[1], dut.y_bank[0]};
	assign debug_state_ddr = dut.state_ddr;
	assign debug_need_y_prep = dut.need_y_prep_c;
	assign debug_need_y_cur = dut.need_y_cur_c;
	assign debug_pending_ready_c = dut.pending_ready_c;
	assign debug_sched_for_pend = dut.sched_for_pending;
endmodule

`default_nettype wire
