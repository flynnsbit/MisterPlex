// present_multi_720p_abi_tb — w-mem / rd-duck BLOCKING MULTI↔L4 DDR ABI coupling.
//
// Shipping recipe under test (w-clock): PRESENT_MULTI_PIXEL + PPC2 + FRAME 1280×720.
// Must select Option-C 720p banks (not L4-only FS_* fallthrough to 480p).
//
// Also covers:
//   - LINE_COUNT default ≥16 on 720p canvas (8 lines = 256 µs < 500 µs model)
//   - L4-only path still forces tier without FRAME 1280
//   - 480p FRAME stays on legacy banks
//   - FAULT_FORCE_480 twin goes RED (test teeth)
//
// No Quartus. No device. Verilator elab + initial checks only.

`timescale 1ns/1ps

module present_multi_720p_abi_tb;
	// ---- Case A: MULTI identity canvas (shipping recipe) --------------------
	// Mirror present_core FRAME defaults under MULTI@1280×720 (no L4).
`ifndef CASE_L4_ONLY
`ifndef CASE_480P
`ifndef CASE_FAULT_480
	localparam int FRAME_W = 1280;
	localparam int FRAME_H = 720;
	// Same default LINE_COUNT rule as present_core (no FRAME_LINES_*).
	localparam int FRAME_LINE_COUNT =
		((FRAME_W == 1280) && (FRAME_H == 720)) ? 16 : 4;

	`include "ddr_frame_layout_params.svh"
	// PRESENT_MULTI_PIXEL is a compile define from the shell; tier keys FRAME.
	`include "plex_ddr_720p_tier.svh"

	// Bind a real store instance so CODED/PHYS/STRIDE/DOORBELL are elaborated
	// under the same FS_* the product present_core wires (not a shadow copy).
	wire clk = 1'b0;
	wire clk_ddr = 1'b0;
	wire reset = 1'b1;
	wire [7:0] fr, fg, fb;
	ddr_frame_store #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.FRAME_STRIDE(FRAME_W),
		.CODED_W(FS_CODED_W),
		.CODED_H(FS_CODED_H),
		.DISPLAY_W(FS_DISPLAY_W),
		.DISPLAY_H(FS_DISPLAY_H),
		.CROP_LEFT(FS_CROP_LEFT),
		.CROP_TOP(FS_CROP_TOP),
		.PRESENT_X(FS_PRESENT_X),
		.PRESENT_Y(FS_PRESENT_Y),
		.LINE_COUNT(FRAME_LINE_COUNT),
		.PHYS_BASE(FS_PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(FS_BANK_STRIDE),
		.DOORBELL_PHYS(FS_DOORBELL),
		.PHYS_BASE_720P(DDR_FRAME_720P_PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES_720P(DDR_FRAME_720P_YUV420P_BANK_STRIDE),
		.DOORBELL_PHYS_720P(DDR_FRAME_720P_YUV420P_DOORBELL_PHYS)
	) u_store (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(11'd0),
		.rd_y(10'd0),
		.rd_active(1'b0),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.geom_enable(1'b0),
		.rt_coded_w(11'd0),
		.rt_coded_h(11'd0),
		.rt_y_stride(12'd0),
		.rt_chroma_stride(11'd0),
		.rt_display_w(11'd0),
		.rt_display_h(11'd0),
		.rt_present_x(11'd0),
		.rt_present_y(11'd0),
		.rt_crop_left(11'd0),
		.rt_crop_top(11'd0),
		.start_req(1'b0),
		.bank_sel(1'b0),
		.status_osd(16'd0),
		.input_cmd_valid(1'b0),
		.input_cmd(8'd0),
		.sdram_test_state(4'd0),
		.sdram_size_code(4'd0),
		.sdram_error_count(16'd0),
		.DDRAM_CLK(),
		.DDRAM_BUSY(1'b0),
		.DDRAM_BURSTCNT(),
		.DDRAM_ADDR(),
		.DDRAM_DOUT(64'd0),
		.DDRAM_DOUT_READY(1'b0),
		.DDRAM_RD(),
		.DDRAM_DIN(),
		.DDRAM_BE(),
		.DDRAM_WE(),
		.vsync_pulse(1'b0),
		.has_frame(),
		.swap_pending(),
		.underrun_count(),
		.frames_done(),
		.doorbell_ok(),
		.debug_state(),
		.geom_hold_black(),
		.geom_hollow_fault()
	);

	initial begin
		if (!PLEX_DDR_720P_TIER)
			$fatal(1, "MULTI@1280x720 must set PLEX_DDR_720P_TIER");
		if (FS_CODED_W != 1280 || FS_CODED_H != 720)
			$fatal(1, "MULTI FS_CODED=%0dx%0d want 1280x720", FS_CODED_W, FS_CODED_H);
		if (FS_PHYS_BASE != 32'h3018_0000)
			$fatal(1, "MULTI FS_PHYS_BASE=%h want 30180000", FS_PHYS_BASE);
		if (FS_BANK_STRIDE != 32'h0018_0000)
			$fatal(1, "MULTI FS_BANK_STRIDE=%h want 00180000", FS_BANK_STRIDE);
		if (FS_DOORBELL != 32'h3047_F000)
			$fatal(1, "MULTI FS_DOORBELL=%h want 3047F000", FS_DOORBELL);
		if (u_store.CODED_W != 1280 || u_store.HPS_BANK_STRIDE_BYTES != 32'h0018_0000)
			$fatal(1, "store params not 720p: CODED_W=%0d STRIDE=%h",
				u_store.CODED_W, u_store.HPS_BANK_STRIDE_BYTES);
		if (u_store.DOORBELL_PHYS != 32'h3047_F000)
			$fatal(1, "store DOORBELL_PHYS=%h want 3047F000", u_store.DOORBELL_PHYS);
		if (FRAME_LINE_COUNT < FS_LINE_COUNT_MIN_720P)
			$fatal(1, "LINE_COUNT=%0d < %0d (MULTI blackout)",
				FRAME_LINE_COUNT, FS_LINE_COUNT_MIN_720P);
		// Blackout arithmetic @ 2 px/clk, 20 MHz, 1280 DE (quoted model).
		// lines * (DE/ppc) / f_clk_us
		begin
			realtime blackout_us;
			blackout_us = (FRAME_LINE_COUNT * (1280.0 / 2.0)) / 20.0; // µs
			if (blackout_us < 500.0)
				$fatal(1, "blackout=%0f us < 500 with LINE_COUNT=%0d",
					blackout_us, FRAME_LINE_COUNT);
			$display("MULTI blackout_us=%0f LINE_COUNT=%0d", blackout_us, FRAME_LINE_COUNT);
		end
		$display("PASS present_multi_720p_abi MULTI+PPC2 tier doorbell=%h stride=%h lines=%0d",
			FS_DOORBELL, FS_BANK_STRIDE, FRAME_LINE_COUNT);
		$finish;
	end
`endif
`endif
`endif

	// ---- Case B: L4 forces tier even if FRAME is still 640×480 ---------------
`ifdef CASE_L4_ONLY
	localparam int FRAME_W = 640;
	localparam int FRAME_H = 480;
	localparam int FRAME_LINE_COUNT = 16;
	`include "ddr_frame_layout_params.svh"
	`include "plex_ddr_720p_tier.svh"
	initial begin
		if (!PLEX_DDR_720P_TIER)
			$fatal(1, "L4 must force PLEX_DDR_720P_TIER with any FRAME");
		if (FS_DOORBELL != 32'h3047_F000)
			$fatal(1, "L4 FS_DOORBELL=%h want 3047F000", FS_DOORBELL);
		if (FS_CODED_W != 1280)
			$fatal(1, "L4 FS_CODED_W=%0d want 1280", FS_CODED_W);
		$display("PASS present_multi_720p_abi L4_ONLY tier doorbell=%h", FS_DOORBELL);
		$finish;
	end
`endif

	// ---- Case C: 480p FRAME stays legacy (no silent 720p) --------------------
`ifdef CASE_480P
	localparam int FRAME_W = 640;
	localparam int FRAME_H = 480;
	localparam int FRAME_LINE_COUNT = 8;
	`include "ddr_frame_layout_params.svh"
	`include "plex_ddr_720p_tier.svh"
	initial begin
		if (PLEX_DDR_720P_TIER)
			$fatal(1, "480p FRAME must not set PLEX_DDR_720P_TIER");
		if (FS_DOORBELL != 32'h300F_F000)
			$fatal(1, "480p FS_DOORBELL=%h want 300FF000", FS_DOORBELL);
		if (FS_CODED_W != 624 || FS_BANK_STRIDE != 32'h0008_0000)
			$fatal(1, "480p FS coded/stride wrong: %0d / %h", FS_CODED_W, FS_BANK_STRIDE);
		$display("PASS present_multi_720p_abi 480P legacy doorbell=%h", FS_DOORBELL);
		$finish;
	end
`endif

	// ---- Case D: FAULT twin — tier forced off under 1280 canvas (must RED) ---
`ifdef CASE_FAULT_480
	localparam int FRAME_W = 1280;
	localparam int FRAME_H = 720;
	localparam int FRAME_LINE_COUNT = 16;
	`include "ddr_frame_layout_params.svh"
	`include "plex_ddr_720p_tier.svh"
	initial begin
		// Under FAULT_FORCE_480 the tier is off → 480p banks on a 720p canvas.
		// This is the MULTI coupling bug class. Test expects NONZERO exit.
		if (PLEX_DDR_720P_TIER)
			$fatal(1, "FAULT twin setup broken: tier still on");
		if (FS_DOORBELL == 32'h3047_F000)
			$fatal(1, "FAULT twin setup broken: still 720p doorbell");
		if (FS_CODED_W == 1280)
			$fatal(1, "FAULT twin setup broken: still 720p coded");
		// Intentionally fail the green contract — shell expects rc!=0.
		$fatal(1, "RED present_multi_720p_abi FAULT_FORCE_480 coded=%0d doorbell=%h (480p on 720p canvas)",
			FS_CODED_W, FS_DOORBELL);
	end
`endif
endmodule
