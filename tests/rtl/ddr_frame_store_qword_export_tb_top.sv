// Qword export handoff for multi-pixel free-lunch (w-scaler READ side).
// Compile with +define+DDR_FRAME_STORE_EXPORT_QWORDS.
// PRESENT_X=0 so rd_x == src_x (simple lane math in C++).
`default_nettype none

module ddr_frame_store_qword_export_tb #(
	parameter int LINE_COUNT = 8
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
	output wire [63:0] rd_y_qword,
	output wire [63:0] rd_y_qword_hi,
	output wire        rd_y_hi_valid,
	output wire [63:0] rd_u_qword,
	output wire [63:0] rd_v_qword,
	output wire [10:0] rd_src_x_q,
	output wire        rd_qword_valid,
	output wire        has_frame,
	output wire        swap_pending,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
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

	ddr_frame_store #(
		.FRAME_W(640),
		.FRAME_H(480),
		.FRAME_STRIDE(640),
		.CODED_W(624),
		.CODED_H(480),
		.DISPLAY_W(624),
		.DISPLAY_H(480),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(0),
		.PRESENT_Y(0),
		.MAX_CODED_W(1280),
		.MAX_CODED_H(720),
		.LINE_COUNT(LINE_COUNT),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(524288),
		.DOORBELL_PHYS(32'h300F_F000),
		.MAILBOX_PHYS(32'h300F_F100),
		.INPUT_MAILBOX_PHYS(32'h300F_F108),
		.SDRAM_MAILBOX_PHYS(32'h300F_F110),
		.FRAME_MAILBOX_PHYS(32'h300F_F118),
		.DDR_BURST_MAX(128),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1),
		.WANT_Y_LINE_ONLY(1'b1),
		.PENDING_READY_STICKY_PREP(1'b1),
		.PREP_SLOT_RECYCLE(1'b1)
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
`ifdef DDR_FRAME_STORE_EXPORT_QWORDS
		.rd_y_qword(rd_y_qword),
		.rd_y_qword_hi(rd_y_qword_hi),
		.rd_y_hi_valid(rd_y_hi_valid),
		.rd_u_qword(rd_u_qword),
		.rd_v_qword(rd_v_qword),
		.rd_src_x_q(rd_src_x_q),
		.rd_qword_valid(rd_qword_valid),
`else
		// Elab without define must not hang ports — tie zeros if misbuilt.
`endif
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

`ifndef DDR_FRAME_STORE_EXPORT_QWORDS
	assign rd_y_qword = 64'd0;
	assign rd_y_qword_hi = 64'd0;
	assign rd_y_hi_valid = 1'b0;
	assign rd_u_qword = 64'd0;
	assign rd_v_qword = 64'd0;
	assign rd_src_x_q = 11'd0;
	assign rd_qword_valid = 1'b0;
`endif
endmodule
`default_nettype wire
