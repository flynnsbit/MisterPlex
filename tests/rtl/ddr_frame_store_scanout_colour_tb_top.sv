// Product-geometry colour / stripe red-check for ddr_frame_store (c5382bee class).
// Uses silicon coded canvas 624-wide (Y 78 qwords / C 39 qwords), presented 640
// with PRESENT_X=11 / DISPLAY_W=618 — same params as the leftedge3 fit map.rpt.
//
// Shell builds two packs against the SAME product RTL defaults:
//   A) chroma_zero  — Y content, U=V=0  → must REPRO green_cast (silicon mean~72 class)
//   B) product_uv   — Y content, U=V=128 + blue probe → must PASS neutral/blue
// Optional -D fault twin (chroma luma stride) is built as case C when requested.
`default_nettype none

module ddr_frame_store_scanout_colour_tb #(
	parameter int LINE_COUNT = 8
)(
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire [9:0]  rd_x,
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

	// Product geometry (map.rpt leftedge3 / c5382bee): CODED 624, DISPLAY 618,
	// PRESENT 11, FRAME 640. Height kept short for sim speed; strides match silicon.
	ddr_frame_store #(
		.FRAME_W(640),
		.FRAME_H(48),
		.FRAME_STRIDE(640),
		.CODED_W(624),
		.CODED_H(48),
		.DISPLAY_W(618),
		.DISPLAY_H(40),
		.CROP_LEFT(0),
		.CROP_TOP(0),
		.PRESENT_X(11),
		.PRESENT_Y(0),
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
endmodule
`default_nettype wire
