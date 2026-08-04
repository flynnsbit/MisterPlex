// SCALAR NEG control (rd-duck): PX_PER_CLK=1 store + {r,r} replicate pad.
// A true PPC2 distinct gate MUST fail this (equal odd/even lanes).
// Beat-delta bus TB is intentionally insensitive to this — refill is full-line.
`default_nettype none

module ddr_frame_store_scalar_neg_tb (
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
	// Padded dual-lane view — SCALAR REPLICATE of scalar outputs.
	output wire [15:0] rd_r_n,
	output wire [15:0] rd_g_n,
	output wire [15:0] rd_b_n,
	output wire [1:0]  rd_lane_valid_n,
	output wire        rd_n_valid,
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
	wire [7:0] s_r_n, s_g_n, s_b_n;
	wire       s_lv;
	wire       s_nv;

	ddr_frame_store #(
		.FRAME_W(1280),
		.FRAME_H(720),
		.FRAME_STRIDE(1280),
		.CODED_W(1280),
		.CODED_H(720),
		.DISPLAY_W(1280),
		.DISPLAY_H(720),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(0),
		.PRESENT_Y(0),
		.LINE_COUNT(16),
		.PHYS_BASE(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES(32'h0018_0000),
		.DOORBELL_PHYS(32'h3047_F000),
		.MAILBOX_PHYS(32'h3047_F100),
		.INPUT_MAILBOX_PHYS(32'h3047_F108),
		.SDRAM_MAILBOX_PHYS(32'h3047_F110),
		.FRAME_MAILBOX_PHYS(32'h3047_F118),
		.BANK_MAILBOX_PHYS(32'h3047_F128),
		.DDR_BURST_MAX(128),
		.IGNORE_STALE_DOORBELL_AFTER_RESET(1'b0),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1),
		.PX_PER_CLK(1)
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
		.rd_r_n(s_r_n),
		.rd_g_n(s_g_n),
		.rd_b_n(s_b_n),
		.rd_lane_valid_n(s_lv),
		.rd_n_valid(s_nv),
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

	// SCALAR REPLICATE pad — models present_core {PPC{fr}} bug / scaler no-rd_*_n.
	// Distinct checker must FAIL (lane0==lane1 always when both "valid").
	assign rd_r_n = {rd_r, rd_r};
	assign rd_g_n = {rd_g, rd_g};
	assign rd_b_n = {rd_b, rd_b};
	assign rd_lane_valid_n = {s_lv, s_lv};
	assign rd_n_valid = s_nv;
	wire _unused_s_n = |{s_r_n, s_g_n, s_b_n};
endmodule
`default_nettype wire
