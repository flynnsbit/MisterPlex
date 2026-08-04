// 720p timing constants + same-clock refresh arithmetic (w-clock).
//
// Product default path does NOT use this module alone. PRESENT_MULTI_PIXEL selects
// present_beam_ppc parameterized from the same COMPACT totals (H=1600 V=750).
//
// Pixel clocks (exact arithmetic — do not round):
//   VIC 4  720p60: H_TOTAL=1650, V_TOTAL=750
//     f_pix = 1650 * 750 * 60 = 74_250_000 Hz = **74.25 MHz**
//   VIC 60 720p24: H_TOTAL=3300, V_TOTAL=750  (double H blanking)
//     f_pix = 3300 * 750 * 24 = 59_400_000 Hz = **59.40 MHz**
//   PRODUCT fabric COMPACT (shared PLL 28.8 MHz — exact 24.000):
//     H_TOTAL=1600, V_TOTAL=750
//     f_pix = 1600 * 750 * 24 = **28_800_000 Hz**; fps_eff = **24.000 Hz**
//   Retired: H1650 @ 30 MHz → 24.242 Hz (false product); 29.7 illegal on shared VCO
//   PIX_PER_FRAME (this pack) = 1600 * 750 = 1_200_000
//
// HONEST RATE (do not conflate with 2ppc fabric math):
//   MiSTer accepts 1 RGB sample per CE_PIXEL. With clk_pix == clk_sys == 20 MHz
//   and CE=1, output pixel rate is **20.0 Mpix/s**, independent of PX_PER_CLK.
//
// Until PRESENT_CLK_PIX_PLL, same-clock mode runs COMPACT totals at reduced refresh:
//   fps_eff = clk_pix / (H_TOTAL * V_TOTAL)
//   @20 MHz, 1600×750: fps_eff = 20e6/1_200_000 ≈ **16.667 Hz**  ← stills trap
//   @28.8 MHz, 1600×750: fps_eff = **24.000 Hz** ← product
// Active geometry is still genuine 1280×720 DE.
//
// Template H_DE=529 (colorbars / FBAR) is a separate mode — never retcon here.

module present_video_timing_720p #(
	parameter int CLK_PIX_HZ = 20_000_000
)(
	output wire [11:0] h_de,
	output wire [11:0] h_total,
	output wire [11:0] v_active,
	output wire [11:0] v_total,
	output wire [11:0] h_sync_s,
	output wire [11:0] h_sync_e,
	output wire [11:0] v_sync_s,
	output wire [11:0] v_sync_e,
	output wire [15:0] fps_eff_milli, // effective refresh * 1000 at CLK_PIX_HZ
	output wire        cea_24_needs_faster_pix // 1 if CLK_PIX_HZ < product 28.8 MHz
);
	// COMPACT fabric 720p product (H1600 — exact-24 @ 28.8 MHz shared PLL)
	localparam int H_DE_L     = 1280;
	localparam int H_TOTAL_L  = 1600;
	localparam int V_ACTIVE_L = 720;
	localparam int V_TOTAL_L  = 750;
	// H blank=320: front=110, sync=40, back=170 (sync window still 1390..1430)
	localparam int H_SYNC_S_L = 1390;
	localparam int H_SYNC_E_L = 1430;
	localparam int V_SYNC_S_L = 725;
	localparam int V_SYNC_E_L = 730;

	localparam int PIX_PER_FRAME = H_TOTAL_L * V_TOTAL_L; // 1_200_000
	// 64-bit math: 20e6*1000 overflows 32-bit int (would corrupt fps_eff).
	localparam longint FPS_MILLI =
		(longint'(CLK_PIX_HZ) * 1000) / longint'(PIX_PER_FRAME); // trunc toward 0
	// Product target clk_pix (shared PLL 28.8 MHz)
	localparam int PRODUCT_PIX_HZ = 28_800_000;

	assign h_de     = 12'(H_DE_L);
	assign h_total  = 12'(H_TOTAL_L);
	assign v_active = 12'(V_ACTIVE_L);
	assign v_total  = 12'(V_TOTAL_L);
	assign h_sync_s = 12'(H_SYNC_S_L);
	assign h_sync_e = 12'(H_SYNC_E_L);
	assign v_sync_s = 12'(V_SYNC_S_L);
	assign v_sync_e = 12'(V_SYNC_E_L);
	assign fps_eff_milli = 16'(FPS_MILLI);
	assign cea_24_needs_faster_pix = (CLK_PIX_HZ < PRODUCT_PIX_HZ);
endmodule
