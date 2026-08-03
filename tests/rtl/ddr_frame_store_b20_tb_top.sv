// B20 bank+geometry atomicity oracle.
// Product: PLXG live+seq ⇒ app_* holds until bank-swap vsync; FAULT free-run
// moves app with candidate immediately (REPRO new pitch before swap).
// Mode-exit: intentional geom_enable=0 must not sticky-hollow (permanent black).
// Beam hierarchy: present_beam_geom_lock tracks app_beam_* (not free-running
// live) so delayed pending_ready cannot paint NEW DE on OLD store.
`default_nettype none

module ddr_frame_store_b20_tb (
	input  wire        clk,
	input  wire        clk_ddr,
	input  wire        reset,
	input  wire        geom_enable,
	input  wire [15:0] rt_geom_seq,
	input  wire        rt_geom_live,
	input  wire [10:0] rt_coded_w,
	input  wire [10:0] rt_coded_h,
	input  wire [11:0] rt_y_stride,
	input  wire [10:0] rt_chroma_stride,
	input  wire [10:0] rt_display_w,
	input  wire [10:0] rt_display_h,
	// Free-running beam dims (latch promote) — lock must ignore under B20.
	input  wire [10:0] live_beam_cw,
	input  wire [10:0] live_beam_ch,
	input  wire [10:0] live_beam_hde,
	input  wire [10:0] live_beam_vde,
	input  wire        vsync_pulse,
	input  wire        start_req,
	input  wire        bank_sel,
	input  wire  [6:0] rd_x,
	input  wire  [5:0] rd_y,
	input  wire        rd_active,
	input  wire        dar_hold_black,
	input  wire        tb_block_pending_ready,
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
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire [10:0] obs_eff_coded_w,
	output wire [10:0] obs_app_coded_w,
	output wire [10:0] obs_app_disp_w,
	output wire [10:0] obs_app_disp_h,
	output wire        obs_app_geom_en,
	output wire        obs_b20_atomic,
	output wire        obs_pend_app_valid,
	output wire        obs_disp_bank,
	output wire        obs_pending_bank,
	output wire        obs_geom_hollow,
	output wire        obs_geom_reject,
	output wire        obs_geom_hold_black,
	output wire [10:0] obs_app_beam_cw,
	output wire [10:0] obs_locked_beam_cw,
	output wire [10:0] obs_locked_beam_hde,
	output wire        obs_beam_use_app,
	output wire [15:0] obs_applied_seq,
	output wire        obs_b20_visual_hold
);
	wire DDRAM_CLK;
	wire [7:0] DDRAM_BE;
	wire [7:0] debug_state;
	wire [15:0] underrun_count;
	wire geom_hold_black, geom_hollow_fault;
	wire [10:0] app_beam_cw_w, app_beam_ch_w, app_beam_hde_w, app_beam_vde_w;

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
		.rt_geom_seq(rt_geom_seq),
		.rt_geom_live(rt_geom_live),
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
		.rt_beam_cw(live_beam_cw),
		.rt_beam_ch(live_beam_ch),
		.rt_beam_hde(live_beam_hde),
		.rt_beam_vde(live_beam_vde),
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
		.geom_hollow_fault(geom_hollow_fault),
		.dar_hold_black(dar_hold_black),
		.tb_block_pending_ready(tb_block_pending_ready),
		.app_beam_cw(app_beam_cw_w),
		.app_beam_ch(app_beam_ch_w),
		.app_beam_hde(app_beam_hde_w),
		.app_beam_vde(app_beam_vde_w),
		.app_disp_w_o(),
		.app_disp_h_o(),
		.app_geom_en_o(),
		.applied_geom_seq_o(obs_applied_seq),
		.b20_visual_hold(obs_b20_visual_hold)
	);

	present_beam_geom_lock beam_lock (
		.live_valid(rt_geom_live),
		.live_seq(rt_geom_seq),
		.live_cw(live_beam_cw),
		.live_ch(live_beam_ch),
		.live_hde(live_beam_hde),
		.live_vde(live_beam_vde),
		.app_cw(app_beam_cw_w),
		.app_ch(app_beam_ch_w),
		.app_hde(app_beam_hde_w),
		.app_vde(app_beam_vde_w),
		.use_app(obs_beam_use_app),
		.out_cw(obs_locked_beam_cw),
		.out_ch(),
		.out_hde(obs_locked_beam_hde),
		.out_vde()
	);

	assign obs_app_beam_cw = app_beam_cw_w;

	assign obs_eff_coded_w    = dut.eff_coded_w;
	assign obs_app_coded_w    = dut.app_coded_w;
	assign obs_app_disp_w     = dut.app_disp_w;
	assign obs_app_disp_h     = dut.app_disp_h;
	assign obs_app_geom_en    = dut.app_geom_en;
	assign obs_b20_atomic     = dut.b20_atomic;
	assign obs_pend_app_valid = dut.pend_app_valid;
	assign obs_disp_bank      = dut.disp_bank;
	assign obs_pending_bank   = dut.pending_bank;
	assign obs_geom_hollow    = geom_hollow_fault;
	assign obs_geom_reject    = dut.geom_reject_r;
	assign obs_geom_hold_black = geom_hold_black;
endmodule

`default_nettype wire
