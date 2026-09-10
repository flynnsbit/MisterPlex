// Testbench-only wrapper for warm core reload of the HPS DDR YUV frame store.
// External DDR contents intentionally survive reset; only the RTL is reset.
`default_nettype none

module ddr_frame_store_warm_reset_tb #(
	parameter bit IGNORE_STALE_DOORBELL_AFTER_RESET = 1'b1,
	parameter int STALE_DOORBELL_FALLBACK_POLLS = 4096,
	parameter bit PIPELINE_REFILL_SCHEDULER = 1'b1,
	parameter bit STRICT_YUV_DOORBELL = 1'b1
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
	input  wire        input_cmd_valid,
	input  wire [7:0]  input_cmd,
	input  wire [15:0] status_osd,
	input  wire        test_override_disp_sync,
	input  wire        test_disp_sync,
	input  wire        test_override_pending_sync,
	input  wire        test_pending_sync,
	input  wire        test_override_start_sync,
	input  wire        test_start_sync,
	output wire [7:0]  rd_r,
	output wire [7:0]  rd_g,
	output wire [7:0]  rd_b,
	output wire        has_frame,
	output wire        swap_pending,
	output wire [15:0] underrun_count,
	output wire [15:0] frames_done,
	output wire        doorbell_ok,
	output wire        debug_sched_valid,
	output wire [15:0] debug_underrun_safe,
	output wire [15:0] debug_osd_hold,
	output wire [15:0] debug_osd_captured,
	output wire        debug_osd_request,
	output wire        debug_osd_seen,
	output wire        debug_osd_ack_sync,
	output wire        debug_osd_ready,
	output wire        debug_pending_ready,
	output wire        debug_pending_ready_id,
	output wire        debug_pending_req_id,
	output wire        debug_disp_buf,
	output wire        debug_disp_buf_d2,
	output wire        debug_queued_refresh_valid,
	output wire        debug_queued_refresh_wait_swap,
	output wire        debug_swap_pending_d2,
	output wire        debug_start_d2,
	output wire        debug_start_seen,
	output wire        debug_bank_sel_d2,
	output wire        debug_pending_bank_ddr,
	output wire        debug_queued_refresh_bank,
	output wire        debug_publication_cache_pending,
	output wire        debug_queue_retire_opportunity,
	output wire [7:0]  debug_y_valid,
	output wire [7:0]  debug_c_valid,
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
		.FRAME_W(80),
		.FRAME_H(48),
		.FRAME_STRIDE(80),
		.CODED_W(80),
		.CODED_H(48),
		.DISPLAY_W(64),
		.DISPLAY_H(48),
		.LINE_COUNT(4),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(65536),
		.DOORBELL_PHYS(32'h3001_F000),
		.MAILBOX_PHYS(32'h3001_F100),
		.INPUT_MAILBOX_PHYS(32'h3001_F108),
		.SDRAM_MAILBOX_PHYS(32'h3001_F110),
		.FRAME_MAILBOX_PHYS(32'h3001_F118),
		.DDR_BURST_MAX(8),
		.IGNORE_STALE_DOORBELL_AFTER_RESET(IGNORE_STALE_DOORBELL_AFTER_RESET),
		.STALE_DOORBELL_FALLBACK_POLLS(STALE_DOORBELL_FALLBACK_POLLS),
		.PIPELINE_REFILL_SCHEDULER(PIPELINE_REFILL_SCHEDULER),
		.STRICT_YUV_DOORBELL(STRICT_YUV_DOORBELL)
	) dut (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.generation_clear(1'b0), .generation_idle(),
		.rd_x(rd_x),
		.rd_y(rd_y),
		.rd_active(rd_active),
		.rd_r(rd_r),
		.rd_g(rd_g),
		.rd_b(rd_b),
		.start_req(start_req),
		.bank_sel(bank_sel),
		.status_osd(status_osd),
		.input_cmd_valid(input_cmd_valid),
		.input_cmd(input_cmd),
		.ioctl_download(1'b0), .ioctl_wr(1'b0),
		.ioctl_dout(8'd0), .ioctl_index(16'd0),
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
	assign debug_underrun_safe = dut.underrun_safe;
	assign debug_osd_hold = dut.status_osd_hold;
	assign debug_osd_captured = dut.status_osd_safe;
	assign debug_osd_request = dut.status_osd_toggle;
	assign debug_osd_seen = dut.status_osd_tog_seen;
`ifdef DDR_FRAME_STORE_TEST_REFERENCE_R2
	assign debug_osd_ack_sync = 1'b0;
`else
	assign debug_osd_ack_sync = dut.status_osd_ack_sync;
`endif
`ifdef OSD_RESET_EPOCH_CANDIDATE
	assign debug_osd_ready = dut.status_osd_ready_sync;
`else
	assign debug_osd_ready = 1'b0;
`endif
	assign debug_pending_ready = dut.pending_ready_s2;
	assign debug_pending_ready_id = dut.pending_ready_id_s2;
	assign debug_pending_req_id = dut.pending_req_id;
	assign debug_disp_buf = dut.disp_buf;
	assign debug_disp_buf_d2 = dut.disp_buf_d2;
	assign debug_queued_refresh_valid = dut.queued_refresh_valid;
	assign debug_queued_refresh_wait_swap = dut.queued_refresh_wait_swap;
	assign debug_swap_pending_d2 = dut.swap_pending_d2;
	assign debug_start_d2 = dut.start_d2;
	assign debug_start_seen = dut.start_seen;
	assign debug_bank_sel_d2 = dut.bank_sel_d2;
	assign debug_pending_bank_ddr = dut.pending_bank_ddr;
	assign debug_queued_refresh_bank = dut.queued_refresh_bank;
	assign debug_publication_cache_pending = dut.publication_cache_pending;
	assign debug_y_valid = dut.y_valid;
	assign debug_c_valid = dut.c_valid;
`ifdef DDR_FRAME_STORE_TEST_REFERENCE_R2
	assign debug_queue_retire_opportunity = dut.queued_refresh_valid &&
		(!dut.queued_refresh_wait_swap || !dut.swap_pending_d2) &&
		dut.state_ddr == 0 && !dut.poll_pending && !DDRAM_RD && !DDRAM_WE;
`else
	assign debug_queue_retire_opportunity = dut.queued_refresh_valid &&
		!dut.legacy_swap_active && !dut.publication_cache_pending &&
		dut.state_ddr == 0 && !dut.poll_pending && !DDRAM_RD && !DDRAM_WE;
`endif
	// Mirror the original second stages exactly unless observation is delayed.
	// Permanent forces avoid release/NBA ambiguity in the simulator.
	reg normal_disp_sync, normal_pending_sync, normal_start_sync;
	always @(posedge clk_ddr) begin
		if (dut.reset_ddr) begin
			normal_disp_sync <= 0;
			normal_pending_sync <= 0;
			normal_start_sync <= 0;
		end else begin
			normal_disp_sync <= dut.disp_buf_d1;
			normal_pending_sync <= dut.swap_pending_d1;
			normal_start_sync <= dut.start_d1;
		end
	end
	initial begin
		force dut.disp_buf_d2 = test_override_disp_sync ? test_disp_sync : normal_disp_sync;
		force dut.swap_pending_d2 = test_override_pending_sync ? test_pending_sync : normal_pending_sync;
		force dut.start_d2 = test_override_start_sync ? test_start_sync : normal_start_sync;
	end
endmodule

`default_nettype wire
