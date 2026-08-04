// MULTI+PPC2 shipping-recipe ddr_frame_store TB (sim only).
//
// Recipe under test (w-clock / rd-duck BLOCKING):
//   PRESENT_MULTI_PIXEL + PRESENT_PX_PER_CLK=2 + FRAME 1280×720
//   → 720p DDR ABI (phys 0x30180000 / stride 0x180000 / doorbell 0x3047F000)
//   → LINE_COUNT floor 32 (measured: LC8/16 underrun 500µs@PPC2/20MHz; LC32 OK)
//
// L4 and MULTI are mutually exclusive as beam modes; this TB does NOT define
// PLEX_PRESENT_720P_L4. It binds the store the same way present_core does under
// MULTI via ddr_frame_abi_select / FS_* (720p tier from FRAME 1280×720).
//
// PX_PER_CLK defaults to 2 (shipping). LINE_COUNT variable under test.
`default_nettype none

module ddr_frame_store_multi_ppc2_tb #(
	parameter int LINE_COUNT = 32,
	parameter int PX_PER_CLK = 2,
	parameter int FRAME_W = 1280,
	parameter int FRAME_H = 720,
	parameter int CODED_W = 1280,
	parameter int CODED_H = 720,
	parameter int DISPLAY_W = 1280,
	parameter int DISPLAY_H = 720,
	// Fault twin: force 480p bank base (wrong ABI) — fullframe must go RED.
	parameter bit FAULT_480P_ABI = 1'b0,
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
	output wire [PX_PER_CLK*8-1:0] rd_r_n,
	output wire [PX_PER_CLK*8-1:0] rd_g_n,
	output wire [PX_PER_CLK*8-1:0] rd_b_n,
	output wire [PX_PER_CLK-1:0]   rd_lane_valid_n,
	output wire        rd_n_valid,
	output wire        has_frame,
	output wire        swap_pending,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
	output wire        debug_sched_valid,
	output wire [7:0]  debug_state,
	// Elaborated ABI readback (C++ asserts shipping constants).
	output wire [31:0] abi_phys_base,
	output wire [31:0] abi_bank_stride,
	output wire [31:0] abi_doorbell,
	output wire [15:0] abi_line_count,
	output wire [7:0]  abi_px_per_clk,
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

	// Mirror present_core MULTI path: FRAME 1280×720 → shared 720p ABI select.
	// (No PLEX_PRESENT_720P_L4 — proves MULTI recipe, not L4-only.)
`include "ddr_frame_layout_params.svh"
	localparam int FS_CODED_W = DDR_FRAME_720P_CODED_WIDTH;
	localparam int FS_CODED_H = DDR_FRAME_720P_CODED_HEIGHT;
	localparam int FS_DISPLAY_W = DDR_FRAME_720P_DISPLAY_WIDTH;
	localparam int FS_DISPLAY_H = DDR_FRAME_720P_DISPLAY_HEIGHT;
	localparam [31:0] FS_PHYS_BASE_OK = DDR_FRAME_720P_PHYS_BASE;
	localparam int FS_BANK_STRIDE_OK = DDR_FRAME_720P_YUV420P_BANK_STRIDE;
	localparam [31:0] FS_DOORBELL_OK = DDR_FRAME_720P_YUV420P_DOORBELL_PHYS;
	// Product MULTI floors LINE_COUNT to 32 when QSF still has FRAME_LINES_8
	// (measured: 16 underruns 500 µs @ PPC2/20MHz through real store).
	localparam int FS_LINE_COUNT = (LINE_COUNT < 32) ? 32 : LINE_COUNT;

	// FAULT twin keeps 480p banks while FRAME is still 1280×720 (rd-duck class).
	localparam [31:0] PHYS_BASE =
		FAULT_480P_ABI ? 32'h3000_0000 : FS_PHYS_BASE_OK;
	localparam int BANK_STRIDE =
		FAULT_480P_ABI ? 32'h0008_0000 : FS_BANK_STRIDE_OK;
	localparam [31:0] DOORBELL =
		FAULT_480P_ABI ? 32'h300F_F000 : FS_DOORBELL_OK;

	// When FAULT_480P_ABI=0, TB still exposes the *intended* MULTI floor so the
	// shell can prove LINE_COUNT=8 product QSF would still feed 16 to the store.
	// For underrun red/green we pass LINE_COUNT through unfloored via
	// FORCE_RAW_LINE_COUNT so LC=8 blackout can go RED.
`ifndef FORCE_RAW_LINE_COUNT
	localparam int DUT_LINE_COUNT = FS_LINE_COUNT;
`else
	localparam int DUT_LINE_COUNT = LINE_COUNT;
`endif

	assign abi_phys_base = PHYS_BASE;
	assign abi_bank_stride = BANK_STRIDE;
	assign abi_doorbell = DOORBELL;
	assign abi_line_count = 16'(DUT_LINE_COUNT);
	assign abi_px_per_clk = 8'(PX_PER_CLK);

	// synthesis translate_off
	initial begin
		if (PX_PER_CLK != 1 && PX_PER_CLK != 2 && PX_PER_CLK != 4)
			$error("MULTI TB PX_PER_CLK must be 1|2|4 (got %0d)", PX_PER_CLK);
		if (FRAME_W != 1280 || FRAME_H != 720)
			$error("MULTI shipping TB requires FRAME 1280x720");
	end
	// synthesis translate_on

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
		.LINE_COUNT(DUT_LINE_COUNT),
		.PHYS_BASE(PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(BANK_STRIDE),
		.DOORBELL_PHYS(DOORBELL),
		.MAILBOX_PHYS(32'h3007_F100),
		.INPUT_MAILBOX_PHYS(32'h3007_F108),
		.SDRAM_MAILBOX_PHYS(32'h3007_F110),
		.FRAME_MAILBOX_PHYS(32'h3007_F118),
		.BANK_MAILBOX_PHYS(32'h3007_F128),
		.DDR_BURST_MAX(DDR_BURST_MAX),
		.IGNORE_STALE_DOORBELL_AFTER_RESET(1'b1),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1),
		.PX_PER_CLK(PX_PER_CLK)
	) dut (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(rd_x[$clog2(FRAME_W)-1:0]),
		.rd_y(rd_y[$clog2(FRAME_H)-1:0]),
		.rd_active(rd_active),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.rd_r_n(rd_r_n),
		.rd_g_n(rd_g_n),
		.rd_b_n(rd_b_n),
		.rd_lane_valid_n(rd_lane_valid_n),
		.rd_n_valid(rd_n_valid),
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
