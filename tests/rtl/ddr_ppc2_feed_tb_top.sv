// 720p Option-C store + LINE_COUNT=16 + PX_PER_CLK=2 feed TB top (w-mem).
`default_nettype none
module ddr_ppc2_feed_tb (
	input  wire        clk, clk_ddr, reset,
	input  wire [10:0] rd_x,
	input  wire [6:0]  rd_y,
	input  wire        rd_active, start_req, bank_sel, vsync_pulse,
	output wire [7:0]  rd_r, rd_g, rd_b,
	output wire [15:0] rd_r_n, rd_g_n, rd_b_n,
	output wire [1:0]  rd_lane_valid_n,
	output wire        rd_n_valid, has_frame, swap_pending,
	output wire [15:0] underrun_count, frames_done,
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
	wire DDRAM_CLK; wire [7:0] DDRAM_BE;
	ddr_frame_store #(
		.FRAME_W(1280), .FRAME_H(64), .FRAME_STRIDE(1280),
		.CODED_W(1280), .CODED_H(64), .DISPLAY_W(1280), .DISPLAY_H(64),
		.CROP_LEFT(0), .CROP_TOP(0), .PRESENT_X(0), .PRESENT_Y(0),
		.LINE_COUNT(16),
		.PHYS_BASE(32'h3018_0000), .HPS_BANK_STRIDE_BYTES(32'h0018_0000),
		.DOORBELL_PHYS(32'h3047_F000),
		.PHYS_BASE_720P(32'h3018_0000), .HPS_BANK_STRIDE_BYTES_720P(32'h0018_0000),
		.DOORBELL_PHYS_720P(32'h3047_F000),
		.DDR_BURST_MAX(128), .PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1), .WANT_Y_LINE_ONLY(1'b1),
		.PENDING_READY_STICKY_PREP(1'b1), .PREP_SLOT_RECYCLE(1'b1),
		.PX_PER_CLK(2)
	) dut (
		.clk(clk), .clk_ddr(clk_ddr), .reset(reset),
		.geom_enable(1'b0), .rt_coded_w(11'd0), .rt_coded_h(11'd0),
		.rt_y_stride(12'd0), .rt_chroma_stride(11'd0),
		.rt_display_w(11'd0), .rt_display_h(11'd0),
		.rt_present_x(11'd0), .rt_present_y(11'd0),
		.rt_crop_left(11'd0), .rt_crop_top(11'd0),
		.rd_x(rd_x), .rd_y(rd_y), .rd_active(rd_active),
		.rd_r(rd_r), .rd_g(rd_g), .rd_b(rd_b),
		.rd_r_n(rd_r_n), .rd_g_n(rd_g_n), .rd_b_n(rd_b_n),
		.rd_lane_valid_n(rd_lane_valid_n), .rd_n_valid(rd_n_valid),
		.start_req(start_req), .bank_sel(bank_sel),
		.status_osd(16'd0), .input_cmd_valid(1'b0), .input_cmd(8'd0),
		.sdram_test_state(4'd0), .sdram_size_code(4'd0), .sdram_error_count(16'd0),
		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.vsync_pulse(vsync_pulse), .has_frame(has_frame), .swap_pending(swap_pending),
		.underrun_count(underrun_count), .frames_done(frames_done),
		.doorbell_ok(doorbell_ok), .debug_state(debug_state),
		.geom_hold_black(), .geom_hollow_fault()
	);
endmodule
`default_nettype wire
