// Top for Verilator: bandwidth meter + geom guard (w-mem).
// Instantiates:
//   - GREEN geom: 720p + Option-C 0x180000 stride
//   - RED geom twin: 720p + legacy 0x80000 (FATAL=0, sticky reject)
//   - bandwidth meter @ 90 MHz budget for 24 fps combined R+W
`default_nettype none

module ddr_bw_geom_tb_top (
	input  wire        clk,
	input  wire        reset,

	// ---- geom green (720p / Option-C) ----
	input  wire        g_check_en,
	output wire [31:0] g_frame_bytes,
	output wire [31:0] g_usable_bytes,
	output wire        g_overflow_now,
	output wire        g_overflow_reject,

	// ---- geom red (720p / legacy 512KiB) ----
	input  wire        r_check_en,
	output wire [31:0] r_frame_bytes,
	output wire [31:0] r_usable_bytes,
	output wire        r_overflow_now,
	output wire        r_overflow_reject,

	// ---- bandwidth meter ----
	input  wire        bw_start,
	input  wire        bw_beat_fire,
	output wire        bw_busy,
	output wire        bw_done,
	output wire        bw_budget_fail,
	output wire [31:0] bw_cycles,
	output wire [31:0] bw_beats,
	output wire [31:0] bw_target_beats,
	output wire [31:0] bw_budget_cycles,

	// ---- line spill smoke ----
	input  wire        sp_wr_en,
	input  wire [10:0] sp_wr_addr,
	input  wire [7:0]  sp_wr_data,
	input  wire        sp_commit,
	input  wire        sp_rd_en,
	input  wire [10:0] sp_rd_addr,
	output wire [7:0]  sp_rd_data,
	output wire        sp_rd_valid,
	output wire        sp_busy,
	output wire        sp_done,
	output wire        sp_ready,

	// ---- contended multi-client (24 fps budget) ----
	input  wire        c24_start,
	input  wire        c24_host_en,
	input  wire        c24_scan_en,
	input  wire        c24_spill_en,
	output wire        c24_busy,
	output wire        c24_done,
	output wire        c24_budget_fail,
	output wire [31:0] c24_cycles,
	output wire [31:0] c24_host_beats,
	output wire [31:0] c24_scan_beats,
	output wire [31:0] c24_total_beats,
	output wire [31:0] c24_host_target,
	output wire [31:0] c24_scan_target,
	output wire [31:0] c24_budget,

	// ---- contended tiny-budget NEG (starvation / miss) ----
	input  wire        cneg_start,
	input  wire        cneg_host_en,
	input  wire        cneg_scan_en,
	output wire        cneg_busy,
	output wire        cneg_done,
	output wire        cneg_budget_fail,
	output wire [31:0] cneg_cycles,
	output wire [31:0] cneg_total_beats
);

	// Green: 1280x720 into 0x180000 bank — must NOT reject.
	ddr_bank_geom_guard #(
		.CODED_W(1280),
		.CODED_H(720),
		.Y_STRIDE(1280),
		.C_STRIDE(640),
		.BANK_STRIDE(32'h0018_0000),
		.DOORBELL_PAGE(32'h1000),
		.FATAL_ON_STATIC_OVERFLOW(1'b0)
	) u_geom_green (
		.clk(clk),
		.reset(reset),
		.rt_frame_bytes(32'd0),
		.rt_bank_stride(32'd0),
		.check_en(g_check_en),
		.frame_bytes(g_frame_bytes),
		.usable_bytes(g_usable_bytes),
		.overflow_now(g_overflow_now),
		.overflow_reject(g_overflow_reject)
	);

	// Red twin: same 720p payload, legacy 512 KiB stride — MUST sticky-reject.
	// FATAL=0 so elab succeeds; runtime sticky is the LOUD path under test.
	ddr_bank_geom_guard #(
		.CODED_W(1280),
		.CODED_H(720),
		.Y_STRIDE(1280),
		.C_STRIDE(640),
		.BANK_STRIDE(32'h0008_0000),
		.DOORBELL_PAGE(32'h1000),
		.FATAL_ON_STATIC_OVERFLOW(1'b0)
	) u_geom_red (
		.clk(clk),
		.reset(reset),
		.rt_frame_bytes(32'd0),
		.rt_bank_stride(32'd0),
		.check_en(r_check_en),
		.frame_bytes(r_frame_bytes),
		.usable_bytes(r_usable_bytes),
		.overflow_now(r_overflow_now),
		.overflow_reject(r_overflow_reject)
	);

	// Combined R+W one 720p frame @ 24 fps budget on 90 MHz clk_ddr.
	ddr_bandwidth_meter #(
		.BEAT_BYTES(8),
		.TARGET_BYTES(1382400),
		.BUDGET_CYCLES(3750000), // 90e6/24
		.COMBINED_RW(1'b1)
	) u_bw (
		.clk(clk),
		.reset(reset),
		.start(bw_start),
		.beat_fire(bw_beat_fire),
		.busy(bw_busy),
		.done(bw_done),
		.budget_fail(bw_budget_fail),
		.cycles(bw_cycles),
		.beats(bw_beats),
		.target_beats(bw_target_beats),
		.budget_cycles_w(bw_budget_cycles)
	);

	sdram_line_spill #(
		.LINE_BYTES(1280),
		.SPILL_LATENCY(4)
	) u_spill (
		.clk(clk),
		.reset(reset),
		.wr_en(sp_wr_en),
		.wr_addr(sp_wr_addr),
		.wr_data(sp_wr_data),
		.wr_line_commit(sp_commit),
		.rd_en(sp_rd_en),
		.rd_addr(sp_rd_addr),
		.rd_data(sp_rd_data),
		.rd_valid(sp_rd_valid),
		.spill_busy(sp_busy),
		.spill_done(sp_done),
		.line_ready(sp_ready)
	);

	// Concurrent host_wr + scan_rd of one 720p I420 each inside 24 fps window.
	ddr_contended_bandwidth #(
		.BEAT_BYTES(8),
		.HOST_WR_BYTES(1382400),
		.SCAN_RD_BYTES(1382400),
		.SPILL_BYTES(0),
		.BUDGET_CYCLES(3750000) // 90e6/24
	) u_c24 (
		.clk(clk),
		.reset(reset),
		.start(c24_start),
		.host_wr_enable(c24_host_en),
		.scan_rd_enable(c24_scan_en),
		.spill_enable(c24_spill_en),
		.busy(c24_busy),
		.done(c24_done),
		.budget_fail(c24_budget_fail),
		.cycles(c24_cycles),
		.host_beats(c24_host_beats),
		.scan_beats(c24_scan_beats),
		.spill_beats(),
		.total_beats(c24_total_beats),
		.host_target(c24_host_target),
		.scan_target(c24_scan_target),
		.spill_target(),
		.budget_w(c24_budget)
	);

	// NEG: same payload, budget only 1000 cycles → must budget_fail even if both enabled.
	ddr_contended_bandwidth #(
		.BEAT_BYTES(8),
		.HOST_WR_BYTES(1382400),
		.SCAN_RD_BYTES(1382400),
		.SPILL_BYTES(0),
		.BUDGET_CYCLES(1000)
	) u_cneg (
		.clk(clk),
		.reset(reset),
		.start(cneg_start),
		.host_wr_enable(cneg_host_en),
		.scan_rd_enable(cneg_scan_en),
		.spill_enable(1'b0),
		.busy(cneg_busy),
		.done(cneg_done),
		.budget_fail(cneg_budget_fail),
		.cycles(cneg_cycles),
		.host_beats(),
		.scan_beats(),
		.spill_beats(),
		.total_beats(cneg_total_beats),
		.host_target(),
		.scan_target(),
		.spill_target(),
		.budget_w()
	);

endmodule

`default_nettype wire
