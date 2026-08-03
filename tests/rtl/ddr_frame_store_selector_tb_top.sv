// Executable RTL bank-selector oracle (rd-duck: host-only edges are not enough).
// Exposes hierarchical eff_* / rt_* so C++ can assert capacity map + U base
// without full scanout. Product params: legacy 0x30000000/0x80000 + Option-C.
//
// FAULT twin: -DDDR_FRAME_STORE_FAULT_FORCE_LEGACY_BANK_MAP keeps optc=0 on
// 960×540 (must REPRO_OK). GOOD: capacity > usable → Option-C.
`default_nettype none

module ddr_frame_store_selector_tb (
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
	input  wire [10:0] rt_present_x,
	input  wire [10:0] rt_present_y,
	input  wire [10:0] rt_crop_left,
	input  wire [10:0] rt_crop_top,
	// Observed selector state (hierarchical — Verilator public)
	output wire        obs_geom_en_r,
	output wire        obs_optc_map,
	output wire        obs_raw_ok,
	output wire        obs_need_optc,
	output wire [31:0] obs_payload_bytes,
	output wire [28:0] obs_base_w0,
	output wire [28:0] obs_doorbell_w,
	output wire [28:0] obs_u_base_qw,
	output wire [28:0] obs_v_base_qw,
	output wire [10:0] obs_coded_w,
	output wire [10:0] obs_coded_h,
	output wire [8:0]  obs_y_fetch_qw,
	output wire [7:0]  obs_c_fetch_qw,
	output wire [7:0]  obs_debug_state,
	output wire        obs_geom_reject_r,
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
	wire [7:0] rd_r, rd_g, rd_b, debug_state;
	wire has_frame, swap_pending, doorbell_ok;
	wire [15:0] underrun_count, frames_done;

	// Tiny FRAME — selector does not need product scanout geometry.
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
		.HPS_BANK_STRIDE_BYTES(524288),
		.DOORBELL_PHYS(32'h300F_F000),
		.PHYS_BASE_720P(32'h3018_0000),
		.HPS_BANK_STRIDE_BYTES_720P(32'h0018_0000),
		.DOORBELL_PHYS_720P(32'h3047_F000),
		.MAILBOX_PHYS(32'h300F_F100),
		.INPUT_MAILBOX_PHYS(32'h300F_F108),
		.SDRAM_MAILBOX_PHYS(32'h300F_F110),
		.FRAME_MAILBOX_PHYS(32'h300F_F118),
		.DDR_BURST_MAX(8),
		.PIPELINE_REFILL_SCHEDULER(1'b1),
		.STRICT_YUV_DOORBELL(1'b1)
	) dut (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(6'd0),
		.rd_y(5'd0),
		.rd_active(1'b0),
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
		.rt_present_x(rt_present_x),
		.rt_present_y(rt_present_y),
		.rt_crop_left(rt_crop_left),
		.rt_crop_top(rt_crop_top),
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
		.vsync_pulse(1'b0),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(underrun_count),
		.frames_done(frames_done),
		.doorbell_ok(doorbell_ok),
		.debug_state(debug_state)
	);

	assign obs_geom_en_r      = dut.geom_en_r;
	assign obs_optc_map       = dut.eff_optc_map;
	assign obs_raw_ok         = dut.rt_raw_ok;
	assign obs_need_optc      = dut.rt_need_optc;
	assign obs_payload_bytes  = dut.rt_payload_bytes;
	assign obs_base_w0        = dut.eff_base_w0;
	assign obs_doorbell_w     = dut.eff_doorbell_w;
	assign obs_u_base_qw      = dut.eff_u_base_qw;
	assign obs_v_base_qw      = dut.eff_v_base_qw;
	assign obs_coded_w        = dut.eff_coded_w;
	assign obs_coded_h        = dut.eff_coded_h;
	assign obs_y_fetch_qw     = dut.eff_y_fetch_qw;
	assign obs_c_fetch_qw     = dut.eff_c_fetch_qw;
	assign obs_debug_state    = debug_state;
	assign obs_geom_reject_r  = dut.geom_reject_r;
endmodule

`default_nettype wire
