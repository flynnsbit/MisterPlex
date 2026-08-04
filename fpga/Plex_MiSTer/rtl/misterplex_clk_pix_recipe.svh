// misterplex_clk_pix_recipe.svh — 720p pixel-clock recipe (w-clock).
// MODULE-LOCAL include OK for localparams; prefer once per module.
//
// =============================================================================
// QUARTUS 17.0.2 HARD FAIL (parent fit, 2026-08-04) — 29.7 MHz IS ILLEGAL
// =============================================================================
// Error (altera_pll.v:749): PLL Output Counter 'output_clock_frequency' illegal
// value '29.7 MHz' on general[3]; Info: "30000000 Hz" is a legal value.
//
// Root cause (integer-N, fractional_vco_multiplier("false")):
//   Shared VCO must be an integer multiple of every output. With clk_sys=20 and
//   clk_ddr=90, VCO ∈ {720,900,1080,1260,1440} MHz. None is divisible by 29.7:
//     720/29.7≈24.24, 900/29.7≈30.30, … (no integer C).
//   Legal near-band fout = VCO/C, e.g. VCO=900: … 31.034, **30.000**, 29.032 …
//   Quartus cited 30 MHz — that is the product default below.
//
// Parent claim VERIFIED: exact 24.000 Hz at 30 MHz needs HT×VT = 1_250_000
// = 2^4×5^7. No divisor pair with H_TOTAL>1280 and V_TOTAL>720 exists.
//
// PRODUCT (enabled, no present_core edit — beam stays H1650×V750):
//   clk_pix = 30.000000 MHz
//   fps_eff = 30e6 / (1650×750) = 30e6 / 1_237_500 = **24.242424… Hz**
//   A/V vs true-24 content: +10101 ppm → **+0.606 s skew per minute**
//   (stills cannot see this; fabric measure must).
//
// ALT exact-24 (documented, NOT product — needs w-scaler present_core H_TOTAL):
//   clk_pix = 28.800000 MHz (VCO 720/C=25 or 1440/C=50 — integer-legal family)
//   H_TOTAL=1600 V_TOTAL=750 → 1600×750×24 = 28_800_000 exact
//   Active 1280×720 unchanged. Do not enable until beam totals flip.
//
// Do NOT enable 74.25 MHz (720p60 VIC-4) or 59.4 (CEA VIC60) without parent grant.
// PLL SoT: fpga/Plex_MiSTer/rtl/pll/pll_0002.v  (NOT stale pll.v)

// --- PRODUCT COMPACT fabric 720p @ PLL-legal 30 MHz (H1650×V750) ---
localparam int MISTERPLEX_CLKPIX_COMPACT_H     = 1650;
localparam int MISTERPLEX_CLKPIX_COMPACT_V     = 750;
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = 24; // content fps target (glass is 24.242)
localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = 30_000_000; // PLL-legal; was 29.7 (illegal)
// Exact fps_eff milli: 30e6*1000/1237500 = 24242 (24.242 Hz)
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS_MILLI = 24242;
// A/V skew vs true 24: (24.242424-24)/24 * 60 s/min ≈ 0.606 s/min
localparam int MISTERPLEX_CLKPIX_COMPACT_SKEW_MS_PER_MIN = 606;

// --- ALT exact-24 (28.8 MHz × H1600×V750) — not product until beam totals change ---
localparam int MISTERPLEX_CLKPIX_EXACT24_H     = 1600;
localparam int MISTERPLEX_CLKPIX_EXACT24_V     = 750;
localparam int MISTERPLEX_CLKPIX_EXACT24_HZ    = 28_800_000; // 1600*750*24
localparam int MISTERPLEX_CLKPIX_EXACT24_FPS_MILLI = 24000;

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

// PLL integer solutions (document; Quartus picks equivalent C from shared VCO)
// Product 30 MHz: e.g. VCO=900 (with 20→C=45, 90→C=10), pix C=30; M/N=18/1 from 50 MHz
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_M = 18;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_N = 1;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_C = 30;
// ALT 28.8: VCO=720, C=25; M/N=72/5
localparam int MISTERPLEX_CLKPIX_EXACT24_PLL_M = 72;
localparam int MISTERPLEX_CLKPIX_EXACT24_PLL_N = 5;
localparam int MISTERPLEX_CLKPIX_EXACT24_PLL_C = 25;
// CEA24/60 still need fractional or separate PLL (M=297 VCO=1485 incompatible with 20/90)
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_C   = 25;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_C   = 20;

// Default product fabric pix when PRESENT_CLK_PIX_PLL (no 74_25 / no CEA24 macro)
localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ    = MISTERPLEX_CLKPIX_COMPACT_HZ;
localparam int MISTERPLEX_CLKPIX_F24_HZ        = MISTERPLEX_CLKPIX_COMPACT_HZ;
localparam int MISTERPLEX_CLKPIX_F60_HZ        = MISTERPLEX_CLKPIX_CEA60_HZ;
localparam int MISTERPLEX_CLKPIX_CEA_H         = MISTERPLEX_CLKPIX_COMPACT_H;
localparam int MISTERPLEX_CLKPIX_CEA_V         = MISTERPLEX_CLKPIX_COMPACT_V;
localparam int MISTERPLEX_CLKPIX_FPS_24        = 24;
localparam int MISTERPLEX_CLKPIX_FPS_60        = 60;
localparam int MISTERPLEX_CLKPIX_F24_PLL_M     = MISTERPLEX_CLKPIX_COMPACT_PLL_M;
localparam int MISTERPLEX_CLKPIX_F24_PLL_N     = MISTERPLEX_CLKPIX_COMPACT_PLL_N;
localparam int MISTERPLEX_CLKPIX_F24_PLL_C     = MISTERPLEX_CLKPIX_COMPACT_PLL_C;
localparam int MISTERPLEX_CLKPIX_F60_PLL_M     = MISTERPLEX_CLKPIX_CEA60_PLL_M;
localparam int MISTERPLEX_CLKPIX_F60_PLL_N     = MISTERPLEX_CLKPIX_CEA60_PLL_N;
localparam int MISTERPLEX_CLKPIX_F60_PLL_C     = MISTERPLEX_CLKPIX_CEA60_PLL_C;
