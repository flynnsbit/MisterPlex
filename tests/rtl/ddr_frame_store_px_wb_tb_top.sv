// Prove decoder px_wr writeback lands in DDR frame-store memory.
`default_nettype none

module ddr_frame_store_px_wb_tb (
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire        dec_px_wr_en,
	input  wire  [1:0] dec_px_plane,
	input  wire [15:0] dec_px_x,
	input  wire [15:0] dec_px_y,
	input  wire  [7:0] dec_px_data,
	input  wire        vsync_pulse,
	input  wire        rd_active,
	input  wire [6:0]  rd_x,
	input  wire [5:0]  rd_y,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire        disp_bank,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE
);
	wire DDRAM_CLK;
	wire [15:0] underrun_count;
	wire [15:0] frames_done;
	wire doorbell_ok;
	wire swap_pending;
	wire [7:0] debug_state;

	ddr_frame_store #(
		.FRAME_W(80),
		.FRAME_H(48),
		.FRAME_STRIDE(80),
		.CODED_W(80),
		.CODED_H(48),
		.DISPLAY_W(64),
		.DISPLAY_H(48),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(0),
		.PRESENT_Y(0),
		.LINE_COUNT(4),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(65536),
		.DOORBELL_PHYS(32'h3001_F000),
		.MAILBOX_PHYS(32'h3001_F100),
		.INPUT_MAILBOX_PHYS(32'h3001_F108),
		.SDRAM_MAILBOX_PHYS(32'h3001_F110),
		.FRAME_MAILBOX_PHYS(32'h3001_F118),
		.BANK_MAILBOX_PHYS(32'h3001_F128),
		.DDR_BURST_MAX(8),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b0)
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
		.dec_px_wr_en(dec_px_wr_en),
		.dec_px_plane(dec_px_plane),
		.dec_px_x(dec_px_x),
		.dec_px_y(dec_px_y),
		.dec_px_data(dec_px_data),
		.vsync_pulse(vsync_pulse),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(underrun_count),
		.frames_done(frames_done),
		.doorbell_ok(doorbell_ok),
		.debug_state(debug_state)
	);

	assign disp_bank = dut.disp_bank;
endmodule

`default_nettype wire
