// B12: measure ddr_frame_store rd_active→RGB lag at 960×N and 624×N.
`timescale 1ns/1ps
`default_nettype none
module ddr_store_rgb_lag_tb #(
	parameter int CODED_W = 960,
	parameter int CODED_H = 32,
	parameter int FRAME_W = 960,
	parameter int FRAME_H = 32,
	parameter int DISP_W  = 960,
	parameter int DISP_H  = 24,
	parameter int PRESENT_X = 0,
	parameter int LINE_COUNT = 8,
	parameter [31:0] PHYS_BASE = 32'h3018_0000,
	parameter [31:0] BANK_STRIDE = 32'h0018_0000,
	parameter [31:0] DOORBELL = 32'h3047_F000
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire [10:0] rd_x,
	input  wire [10:0] rd_y,
	input  wire        rd_active,
	input  wire        start_req,
	input  wire        bank_sel,
	input  wire        vsync_pulse,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire [15:0] underrun_count,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire        DDRAM_WE
);
	wire DDRAM_CLK; wire [7:0] DDRAM_BE;
	ddr_frame_store #(
		.FRAME_W(FRAME_W), .FRAME_H(FRAME_H), .FRAME_STRIDE(FRAME_W),
		.CODED_W(CODED_W), .CODED_H(CODED_H),
		.DISPLAY_W(DISP_W), .DISPLAY_H(DISP_H),
		.CROP_LEFT(0), .CROP_TOP(0), .PRESENT_X(PRESENT_X), .PRESENT_Y(0),
		.LINE_COUNT(LINE_COUNT),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(BANK_STRIDE),
		.DOORBELL_PHYS(DOORBELL),
		.PHYS_BASE_720P(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES_720P(32'h0018_0000),
		.DOORBELL_PHYS_720P(32'h3047_F000),
		.MAILBOX_PHYS(DOORBELL + 32'h100),
		.INPUT_MAILBOX_PHYS(DOORBELL + 32'h108),
		.SDRAM_MAILBOX_PHYS(DOORBELL + 32'h110),
		.FRAME_MAILBOX_PHYS(DOORBELL + 32'h118),
		.DDR_BURST_MAX(128),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1),
		.WANT_Y_LINE_ONLY(1'b1),
		.PENDING_READY_STICKY_PREP(1'b1),
		.PREP_SLOT_RECYCLE(1'b1)
	) dut (
		.clk(clk), .clk_ddr(clk_ddr), .reset(reset),
		.rd_x(rd_x), .rd_y(rd_y), .rd_active(rd_active),
		.rd_r(rd_r), .rd_g(rd_g), .rd_b(rd_b),
		.start_req(start_req), .bank_sel(bank_sel),
		.status_osd(16'd0), .input_cmd_valid(1'b0), .input_cmd(8'd0),
		.sdram_test_state(4'd0), .sdram_size_code(4'd0), .sdram_error_count(16'd0),
		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE), .vsync_pulse(vsync_pulse),
		.has_frame(has_frame), .swap_pending(), .underrun_count(underrun_count),
		.frames_done(), .doorbell_ok(), .debug_state()
	);
endmodule
`default_nettype wire
