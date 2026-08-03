// Compile-time DDR bank-stride overflow guard (w-mem / w-nostub landmine).
//
// Failure class: FRAME_W×FRAME_H I420 (e.g. 1280×720 = 1_382_400 B) written
// into a 512 KiB (0x80000) bank stride silently corrupts the neighbour bank.
// Same class as MB_WIDTH_MAX under-cap — must be LOUD at build/elab, not silent.
//
// Contract (ddr_frame_layout_params.svh / ddr_frame_layout.hpp):
//   LEGACY usable = 0x80000 − 0x1000 = 520192  (480p coded 449280 fits)
//   Option-C      = 0x180000 − 0x1000 = 1568768 (720p 1382400 fits)
//
// Instantiate once per store/top with the SAME parameters wired to
// ddr_frame_store. Prefer generate $error (elaboration) over runtime-only.
//
// FAULT twin: DDR_BANK_STRIDE_FAULT_720P_ON_LEGACY forces OPTC_STRIDE down to
// LEGACY so a 1280×720 FRAME must $error (negative proof).

module ddr_bank_stride_guard #(
	parameter int FRAME_W = 640,
	parameter int FRAME_H = 480,
	parameter int CODED_W = 624,
	parameter int CODED_H = 480,
	parameter int MAX_W = 1280,
	parameter int MAX_H = 720,
	parameter int LEG_STRIDE = 32'h0008_0000,
	parameter int OPTC_STRIDE = 32'h0018_0000,
	parameter int DOORBELL_PAGE = 32'h1000
) (
	// Optional sticky for sim/TB readback (1 = would reject at elab if soft).
	output wire overflow_fault
);

`ifdef DDR_BANK_STRIDE_FAULT_720P_ON_LEGACY
	// RED TWIN: pretend Option-C was never landed (512 KiB only).
	localparam int EFF_OPTC_STRIDE = LEG_STRIDE;
`else
	localparam int EFF_OPTC_STRIDE = OPTC_STRIDE;
`endif

	localparam int FRAME_I420 = FRAME_W * FRAME_H * 3 / 2;
	localparam int CODED_I420 = CODED_W * CODED_H * 3 / 2;
	localparam int MAX_I420   = MAX_W * MAX_H * 3 / 2;
	localparam int LEG_USABLE = LEG_STRIDE - DOORBELL_PAGE;
	localparam int OPTC_USABLE = EFF_OPTC_STRIDE - DOORBELL_PAGE;

	// Structural predicates (also exported as overflow_fault for TB).
	// CODED_* are the geom_enable=0 LEGACY defaults (product 624×480) and must
	// fit LEG usable. Do not set CODED=1280 unless LEG stride is also 720p —
	// product keeps CODED at 480p and uses MAX/runtime for 720p content.
	localparam bit LEG_CODED_OVF = (CODED_I420 > LEG_USABLE);
	localparam bit MAX_OPTC_OVF  = (MAX_I420 > OPTC_USABLE);
	localparam bit FRAME_BOTH_OVF =
		(FRAME_I420 > LEG_USABLE) && (FRAME_I420 > OPTC_USABLE);
	// Landmine: FRAME (or MAX content class) needs capacity beyond legacy but
	// Option-C stride was never raised (still <= legacy) — neighbour-bank class.
	localparam bit FRAME_SILENT_720P =
		(FRAME_I420 > LEG_USABLE) && (EFF_OPTC_STRIDE <= LEG_STRIDE);
	localparam bit MAX_SILENT_720P =
		(MAX_I420 > LEG_USABLE) && (EFF_OPTC_STRIDE <= LEG_STRIDE);
	// 720p canvas MAX without product 1.5 MiB Option-C stride.
	localparam bit MAX_NEEDS_180000 =
		(MAX_W >= 1280) && (MAX_H >= 720) && (EFF_OPTC_STRIDE < 32'h0018_0000);

	assign overflow_fault = LEG_CODED_OVF | MAX_OPTC_OVF | FRAME_BOTH_OVF |
	                        FRAME_SILENT_720P | MAX_SILENT_720P | MAX_NEEDS_180000;

`ifndef DDR_BANK_STRIDE_GUARD_SOFT
	// Elaboration-time hard fail (Verilator + Quartus analysis).
	// SOFT define keeps the module elaborable for FAULT REPRO TBs that assert
	// overflow_fault==1 without killing the whole compile.
	generate
		if (LEG_CODED_OVF) begin : g_leg_coded
			$error("ddr_bank_stride_guard: legacy CODED %0dx%0d I420=%0d exceeds LEG usable %0d (stride=%0d) — silent bank overflow",
				CODED_W, CODED_H, CODED_I420, LEG_USABLE, LEG_STRIDE);
		end
		if (MAX_OPTC_OVF) begin : g_max_optc
			$error("ddr_bank_stride_guard: MAX %0dx%0d I420=%0d exceeds Option-C usable %0d (stride=%0d)",
				MAX_W, MAX_H, MAX_I420, OPTC_USABLE, EFF_OPTC_STRIDE);
		end
		if (FRAME_BOTH_OVF) begin : g_frame_both
			$error("ddr_bank_stride_guard: FRAME %0dx%0d I420=%0d exceeds LEG usable %0d and Option-C usable %0d",
				FRAME_W, FRAME_H, FRAME_I420, LEG_USABLE, OPTC_USABLE);
		end
		if (FRAME_SILENT_720P) begin : g_silent_720
			$error("ddr_bank_stride_guard: FRAME %0dx%0d I420=%0d > LEG usable %0d but Option-C stride %0d <= LEG %0d — SILENT neighbour-bank corruption (need HPS_BANK_STRIDE_BYTES_720P=0x180000)",
				FRAME_W, FRAME_H, FRAME_I420, LEG_USABLE, EFF_OPTC_STRIDE, LEG_STRIDE);
		end
		if (MAX_SILENT_720P) begin : g_max_silent
			$error("ddr_bank_stride_guard: MAX %0dx%0d I420=%0d > LEG usable but Option-C stride %0d <= LEG %0d — SILENT neighbour-bank corruption",
				MAX_W, MAX_H, MAX_I420, EFF_OPTC_STRIDE, LEG_STRIDE);
		end
		if (MAX_NEEDS_180000) begin : g_need_180
			$error("ddr_bank_stride_guard: MAX 1280x720 requires Option-C stride >= 0x180000 (got 0x%0h)",
				EFF_OPTC_STRIDE);
		end
	endgenerate
`endif

endmodule
