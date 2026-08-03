// B16 fill-drain protocol: geometry invalidate must drain accepted DDR beats
// before any new line RD (no response tags). FAULT_NO_FILL_DRAIN restores the
// force-IDLE path that loses/corrupts beats.
`default_nettype none

module ddr_frame_store_fill_drain_tb (
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire        geom_enable,
	input  wire [10:0] rt_coded_w,
	input  wire [10:0] rt_coded_h,
	input  wire [11:0] rt_y_stride,
	input  wire [10:0] rt_chroma_stride,
	input  wire [10:0] rt_display_w,
	input  wire [10:0] rt_display_h,
	input  wire        rd_active,
	input  wire  [6:0] rd_x,
	input  wire  [5:0] rd_y,
	input  wire        vsync_pulse,
	input  wire        start_req,
	input  wire        bank_sel,
	input  wire        DDRAM_BUSY,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire        DDRAM_WE,
	output wire        has_frame,
	output wire        swap_pending,
	output wire        doorbell_ok,
	output wire [15:0] frames_done,
	output wire  [7:0] debug_state,
	// Hierarchical probes
	output wire  [3:0] obs_state_ddr,
	output wire  [8:0] obs_burst_left,
	output wire        obs_fill_abort,
	output wire        obs_y_wr0,
	output wire  [3:0] obs_geom_epoch,
	output wire  [3:0] obs_d_geom_epoch,
	output wire        obs_y_valid0,
	output wire  [3:0] obs_y_epoch0,
	output wire        obs_sched_valid
);
	wire DDRAM_CLK;
	wire [7:0] DDRAM_BE;
	wire [7:0] rd_r, rd_g, rd_b;
	wire [15:0] underrun_count;
	wire geom_hold_black, geom_hollow_fault;

	// 64×32 coded → 8 Y qwords/line. Burst max 4 → multi-beat WAIT (2 bursts).
	ddr_frame_store #(
		.FRAME_W(64),
		.FRAME_H(32),
		.FRAME_STRIDE(64),
		.CODED_W(64),
		.CODED_H(32),
		.MAX_CODED_W(1280),
		.MAX_CODED_H(720),
		.DISPLAY_W(64),
		.DISPLAY_H(32),
		.PRESENT_X(0),
		.PRESENT_Y(0),
		.LINE_COUNT(4),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(65536),
		.DOORBELL_PHYS(32'h3001_F000),
		.PHYS_BASE_720P(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES_720P(32'h0018_0000),
		.DOORBELL_PHYS_720P(32'h3047_F000),
		.MAILBOX_PHYS(32'h3001_F100),
		.INPUT_MAILBOX_PHYS(32'h3001_F108),
		.SDRAM_MAILBOX_PHYS(32'h3001_F110),
		.FRAME_MAILBOX_PHYS(32'h3001_F118),
		.BANK_MAILBOX_PHYS(32'h3001_F128),
		.DDR_BURST_MAX(4),
		.IGNORE_STALE_DOORBELL_AFTER_RESET(1'b0),
		.PIPELINE_REFILL_SCHEDULER(1'b0),
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
		.geom_enable(geom_enable),
		.rt_coded_w(rt_coded_w),
		.rt_coded_h(rt_coded_h),
		.rt_y_stride(rt_y_stride),
		.rt_chroma_stride(rt_chroma_stride),
		.rt_display_w(rt_display_w),
		.rt_display_h(rt_display_h),
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
		.debug_state(debug_state),
		.geom_hold_black(geom_hold_black),
		.geom_hollow_fault(geom_hollow_fault)
	);

	assign obs_state_ddr    = dut.state_ddr;
	assign obs_burst_left   = dut.burst_left[8:0];
	assign obs_fill_abort   = dut.fill_abort;
	assign obs_y_wr0        = dut.y_wr[0];
	assign obs_geom_epoch   = dut.geom_epoch_r;
	assign obs_d_geom_epoch = dut.d_geom_epoch;
	assign obs_y_valid0     = dut.y_valid[0];
	assign obs_y_epoch0     = dut.y_epoch[0];
	assign obs_sched_valid  = dut.sched_valid;
endmodule

`default_nettype wire
