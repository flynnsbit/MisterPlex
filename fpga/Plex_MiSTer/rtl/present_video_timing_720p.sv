// CEA-861 720p timing constants + same-clock refresh arithmetic (w-clock).
//
// Product default path does NOT use this module. PRESENT_MULTI_PIXEL selects
// present_beam_ppc parameterized from these values.
//
// HONEST RATE (do not conflate with 2ppc fabric math):
//   MiSTer accepts 1 RGB sample per CE_PIXEL. With clk_pix == clk_sys == 20 MHz
//   and CE=1, output pixel rate is **20.0 Mpix/s**, independent of PX_PER_CLK.
//   PX_PER_CLK lowers *fabric* work rate (store/YUV) when clk_pix is faster or
//   when N pixels are produced per sys cycle into a faster pix domain.
//   Same-clock 2ppc does NOT raise scan-out above 20 Mpix/s.
//
// CEA 720p24 full raster needs 29.70 Mpix/s → requires clk_pix ≥ 29.70 MHz
// (see CLK_PIX_PLL_PLAN.md). Until that PLL out exists, same-clock mode runs
// CEA totals at reduced refresh:
//   fps_eff = clk_pix / (H_TOTAL * V_TOTAL)
//   @20 MHz, 1650×750: fps_eff = 20e6/1_237_500 ≈ **16.16 Hz**
// Active geometry is still genuine 1280×720 DE.
//
// Template H_DE=529 (colorbars / FBAR) is a separate mode — never retcon here.

module present_video_timing_720p #(
	parameter int CLK_PIX_HZ = 20_000_000
)(
	// Purely elaborative / readable constants via parameters on the instance.
	// Outputs are wires tied to parameters so hierarchy tools see the mode.
	output wire [11:0] h_de,
	output wire [11:0] h_total,
	output wire [11:0] v_active,
	output wire [11:0] v_total,
	output wire [11:0] h_sync_s,
	output wire [11:0] h_sync_e,
	output wire [11:0] v_sync_s,
	output wire [11:0] v_sync_e,
	output wire [15:0] fps_eff_milli, // effective refresh * 1000 at CLK_PIX_HZ
	output wire        cea_24_needs_faster_pix // 1 if CLK_PIX_HZ < 29_700_000
);
	// CEA-861 720p (same totals for 24/60; rate differs)
	localparam int H_DE_L     = 1280;
	localparam int H_TOTAL_L  = 1650;
	localparam int V_ACTIVE_L = 720;
	localparam int V_TOTAL_L  = 750;
	localparam int H_SYNC_S_L = 1390;
	localparam int H_SYNC_E_L = 1430;
	localparam int V_SYNC_S_L = 725;
	localparam int V_SYNC_E_L = 730;

	localparam int PIX_PER_FRAME = H_TOTAL_L * V_TOTAL_L; // 1_237_500
	// 64-bit math: 20e6*1000 overflows 32-bit int (would corrupt fps_eff).
	localparam longint FPS_MILLI =
		(longint'(CLK_PIX_HZ) * 1000) / longint'(PIX_PER_FRAME); // trunc toward 0

	assign h_de     = 12'(H_DE_L);
	assign h_total  = 12'(H_TOTAL_L);
	assign v_active = 12'(V_ACTIVE_L);
	assign v_total  = 12'(V_TOTAL_L);
	assign h_sync_s = 12'(H_SYNC_S_L);
	assign h_sync_e = 12'(H_SYNC_E_L);
	assign v_sync_s = 12'(V_SYNC_S_L);
	assign v_sync_e = 12'(V_SYNC_E_L);
	assign fps_eff_milli = 16'(FPS_MILLI);
	assign cea_24_needs_faster_pix = (CLK_PIX_HZ < 29_700_000);
endmodule
