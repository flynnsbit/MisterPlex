// misterplex_clk_pix_recipe.svh — 720p pixel-clock recipe (w-clock).
// MODULE-LOCAL include OK for localparams; prefer once per module.
//
// =============================================================================
// ROOT CAUSE (parent fit 2026-08-04) — 29.7 on SHARED pll_0002 is illegal
// =============================================================================
// Error: general[3] '29.7 MHz' illegal; Info: "30000000 Hz" legal.
// Cause: integer-N shared VCO with 20+90. VCO multiple of 180; 180k/29.7 ∈ ℤ
// ⇒ k multiple of 33 ⇒ min VCO = 5940 MHz (Cyclone V fPLL VCO ~600–1600: OOR).
// 30 MHz works on VCO=900 with 20/90 but gives fps_eff=24.242… (+1.01% judder).
// Exact-24 @ 30 MHz needs HT×VT=1_250_000=2^4×5^7 — ZERO pairs H>1280,V>720.
//
// PRODUCT FIX: dedicated pll_pix (rtl/pll/pll_pix_0002.v), OWN VCO:
//   M=297 N=10 → VCO=50*297/10=1485 MHz (IN RANGE)
//   C=50 → 29.700000 MHz → H1650×V750×24 = EXACT 24.000 Hz
// pll_0002 stays number_of_clocks(3) — less invasive to clk_sys/sdram/ddr consumers.
//
// Do NOT re-attach 29.7 to pll_0002 outclk_3.
// Do NOT enable 74.25 (VIC-4 60 Hz) without parent grant.

// --- PRODUCT COMPACT fabric 720p @ 29.7 MHz dedicated PLL (H1650×V750) ---
localparam int MISTERPLEX_CLKPIX_COMPACT_H     = 1650;
localparam int MISTERPLEX_CLKPIX_COMPACT_V     = 750;
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = 24; // glass = content = 24.000 exact
localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = 29_700_000; // dedicated PLL
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS_MILLI = 24000;
localparam int MISTERPLEX_CLKPIX_COMPACT_SKEW_MS_PER_MIN = 0;

// --- Shared-PLL 30 MHz trap (DO NOT SHIP) — photographs as success ---
localparam int MISTERPLEX_CLKPIX_SHARED30_HZ   = 30_000_000;
localparam int MISTERPLEX_CLKPIX_SHARED30_FPS_MILLI = 24242; // 24.242 Hz
localparam int MISTERPLEX_CLKPIX_SHARED30_SKEW_MS_PER_MIN = 606;

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

// Dedicated pll_pix integer solution (SoT)
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_M = 297;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_N = 10;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_C = 50; // 1485/50 = 29.7
localparam int MISTERPLEX_CLKPIX_COMPACT_VCO_MHZ = 1485;
// 74.25 on same VCO
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_C   = 20; // 1485/20 = 74.25
// CEA24 59.4: VCO 1485 C=25
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA24_PLL_C   = 25;

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
