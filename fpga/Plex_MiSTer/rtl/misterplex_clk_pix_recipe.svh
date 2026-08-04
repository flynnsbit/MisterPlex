// misterplex_clk_pix_recipe.svh — 720p pixel-clock recipe (w-clock).
// MODULE-LOCAL include OK for localparams; prefer once per module.
//
// *** TIMING NAME LOCK (rd-duck / v4l2-dv-timings.h) ***
// True CEA-861 1280x720p24 (VIC 60) is NOT H=1650 @ 29.7 MHz.
// Linux V4L2_DV_BT_CEA_1280X720P24:
//   pixelclock = 59_400_000
//   H: front=1760 sync=40 back=220 → Hblank=2020 → Htotal = 1280+2020 = 3300
//   V: front=5 sync=5 back=20 → Vblank=30 → Vtotal = 720+30 = 750
//   VIC = 60
// Check: 3300 * 750 * 24 = 59_400_000 exact.
//
// Fabric COMPACT 720p24 (current MULTI beam defaults H=1650 V=750):
//   Htotal=1650 Vtotal=750 @ 24 → 29_700_000 Hz
//   This is a half-H-blanking / non-CEA input raster. It is NOT CEA-861 720p24.
//   Intended as fabric content clock into MiSTer ascal (scaler produces HDMI timing).
//   Do not call it "CEA 720p24".
//
// CEA-861 720p60 (VIC 4) DOES use H=1650 V=750 @ 74.25 MHz:
//   1650 * 750 * 60 = 74_250_000 exact.
//
// PRODUCT content fps = 24. Preferred fabric glass for MULTI default-off recipe:
//   COMPACT 29.7 MHz (H1650) + ascal, OR true CEA24 59.4 MHz (H3300) if direct CE out.
//   True CEA24 needs ~59.4 Mpix/s → PPC≥3 @20 MHz or PPC=2 @30+ or clk_pix@59.4 (PPC4 safer).
//
// PLL SoT: fpga/Plex_MiSTer/rtl/pll/pll_0002.v  (NOT stale pll.v)
//   refclk = 50.0 MHz
//   outclk_3 default string "29.700000 MHz" = COMPACT 24 path (not CEA24)
//   PRESENT_CLK_PIX_74_25 → "74.250000 MHz" = CEA 720p60 VIC4
//   PRESENT_CLK_PIX_CEA24 → "59.400000 MHz" = true CEA 720p24 VIC60 (optional)
//   fractional_vco_multiplier("false") — integer-N
//
// Exact integer M/N/C from 50 MHz (0 ppm if chosen; fitted Actual UNKNOWN until fit):
//   29.70: M=297 N=10 C=50 (VCO 1485); also 297/20/25
//   59.40: M=297 N=10 C=25 (VCO 1485); also 297/20/12.5 — need integer C:
//          M=297 N=5  C=50 → VCO=2970 too high; M=297 N=10 C=25 → VCO=1485 out=59.4 OK
//   74.25: M=297 N=10 C=20 (VCO 1485); also 297/20/10
//
// pll_hdmi: SEPARATE fractional ~148.5 + pll_hdmi_adj. Not retargeted by this recipe.
// DEFAULT OFF. Parent fit grant + Plex_clk_pix.sdc required.

// --- COMPACT fabric 720p24 (H1650) — NOT CEA VIC60 ---
localparam int MISTERPLEX_CLKPIX_COMPACT_H     = 1650;
localparam int MISTERPLEX_CLKPIX_COMPACT_V     = 750;
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = 24;
localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = 29_700_000; // 1650*750*24

// --- True CEA-861 720p24 VIC60 ---
localparam int MISTERPLEX_CLKPIX_CEA24_H       = 3300;
localparam int MISTERPLEX_CLKPIX_CEA24_V       = 750;
localparam int MISTERPLEX_CLKPIX_CEA24_FPS     = 24;
localparam int MISTERPLEX_CLKPIX_CEA24_HZ      = 59_400_000; // 3300*750*24
localparam int MISTERPLEX_CLKPIX_CEA24_VIC     = 60;
localparam int MISTERPLEX_CLKPIX_CEA24_HFRONT  = 1760;
localparam int MISTERPLEX_CLKPIX_CEA24_HSYNC   = 40;
localparam int MISTERPLEX_CLKPIX_CEA24_HBACK   = 220;

// --- CEA-861 720p60 VIC4 (H1650) ---
localparam int MISTERPLEX_CLKPIX_CEA60_H       = 1650;
localparam int MISTERPLEX_CLKPIX_CEA60_V       = 750;
localparam int MISTERPLEX_CLKPIX_CEA60_HZ      = 74_250_000; // 1650*750*60
localparam int MISTERPLEX_CLKPIX_CEA60_VIC     = 4;

localparam int MISTERPLEX_CLKPIX_REF_HZ        = 50_000_000;

// PLL integer solutions (document; Quartus may pick equivalent)
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_M = 297;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_N = 10;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_C = 50;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_C   = 25;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_C   = 20;

// Default product fabric pix when PRESENT_CLK_PIX_PLL (no 74_25 / no CEA24 macro):
// COMPACT 29.7 — requires ascal for CE HDMI; not CEA24.
localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = MISTERPLEX_CLKPIX_COMPACT_HZ;
// Legacy aliases (name says F24 but value is COMPACT — do not call CEA)
localparam int MISTERPLEX_CLKPIX_F24_HZ        = MISTERPLEX_CLKPIX_COMPACT_HZ;
localparam int MISTERPLEX_CLKPIX_F60_HZ        = MISTERPLEX_CLKPIX_CEA60_HZ;
localparam int MISTERPLEX_CLKPIX_CEA_H         = MISTERPLEX_CLKPIX_COMPACT_H; // legacy name = compact H
localparam int MISTERPLEX_CLKPIX_CEA_V         = MISTERPLEX_CLKPIX_COMPACT_V;
localparam int MISTERPLEX_CLKPIX_FPS_24        = 24;
localparam int MISTERPLEX_CLKPIX_FPS_60        = 60;
localparam int MISTERPLEX_CLKPIX_F24_PLL_M     = MISTERPLEX_CLKPIX_COMPACT_PLL_M;
localparam int MISTERPLEX_CLKPIX_F24_PLL_N     = MISTERPLEX_CLKPIX_COMPACT_PLL_N;
localparam int MISTERPLEX_CLKPIX_F24_PLL_C     = MISTERPLEX_CLKPIX_COMPACT_PLL_C;
localparam int MISTERPLEX_CLKPIX_F60_PLL_M     = MISTERPLEX_CLKPIX_CEA60_PLL_M;
localparam int MISTERPLEX_CLKPIX_F60_PLL_N     = MISTERPLEX_CLKPIX_CEA60_PLL_N;
localparam int MISTERPLEX_CLKPIX_F60_PLL_C     = MISTERPLEX_CLKPIX_CEA60_PLL_C;
