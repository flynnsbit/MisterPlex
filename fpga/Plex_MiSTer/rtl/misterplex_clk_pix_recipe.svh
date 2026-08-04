// misterplex_clk_pix_recipe.svh — 720p pixel-clock recipe (w-clock).
// MODULE-LOCAL include OK for localparams; prefer once per module.
//
// =============================================================================
// PRODUCT: 28.800000 MHz on SHARED pll_0002 outclk_3 (exact 24.000 Hz)
// =============================================================================
// 1600 × 750 × 24 = 28_800_000 EXACT.
// Shared integer-N VCO with clk_sys=20 + clk_ddr=90:
//   VCO = 720 MHz (ref 50 MHz, M=72, N=5, PFD=10 MHz)
//   C20=36, C90=8, Cpix=25 — all integers. Alt VCO=1440 also works.
// Blanking @ H1600×V750: Hblank=320, Vblank=30 (ample). H sync window
//   1390..1430 still fits (front=110, sync=40, back=170).
//
// 29.7 MHz on shared PLL is ILLEGAL (min VCO 5940 MHz) — never enable.
// 30 MHz @ H1650 was a false product (24.242 Hz) — retired; gate rejects 242.
// Dedicated second PLL withdrawn (parent 2026-08-04).
// True CEA24 59.4 MHz not pursued (PPC2 producer ceiling).
// SDRAM: 120 MHz compatible with VCO720; 142 MHz is not — do not re-enable 142 live.

// --- PRODUCT COMPACT fabric 720p @ 28.8 MHz shared PLL (H1600×V750) ---
localparam int MISTERPLEX_CLKPIX_COMPACT_H     = 1600;
localparam int MISTERPLEX_CLKPIX_COMPACT_V     = 750;
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS   = 24; // glass = content = 24.000 exact
localparam int MISTERPLEX_CLKPIX_COMPACT_HZ    = 28_800_000;
localparam int MISTERPLEX_CLKPIX_COMPACT_FPS_MILLI = 24000;
localparam int MISTERPLEX_CLKPIX_COMPACT_SKEW_MS_PER_MIN = 0;
localparam int MISTERPLEX_CLKPIX_COMPACT_H_SYNC_S = 1390;
localparam int MISTERPLEX_CLKPIX_COMPACT_H_SYNC_E = 1430;

// Shared-VCO counter recipe (documentation integers; megafunction derives M/N/C)
localparam int MISTERPLEX_CLKPIX_COMPACT_VCO_MHZ = 720;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_M   = 72;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_N   = 5;
localparam int MISTERPLEX_CLKPIX_COMPACT_PLL_C   = 25; // 720/25 = 28.8
localparam int MISTERPLEX_CLKPIX_COMPACT_C_SYS   = 36; // 720/20
localparam int MISTERPLEX_CLKPIX_COMPACT_C_DDR   = 8;  // 720/90

// --- Retired traps (do not ship) ---
localparam int MISTERPLEX_CLKPIX_ILLEGAL297_HZ = 29_700_000; // shared VCO OOR
localparam int MISTERPLEX_CLKPIX_SHARED30_HZ   = 30_000_000; // was 24.242 @ H1650
localparam int MISTERPLEX_CLKPIX_SHARED30_FPS_MILLI = 24242;
localparam int MISTERPLEX_CLKPIX_LEGACY1650_H  = 1650; // retired compact H

// --- True CEA-861 720p24 VIC60 ---
localparam int MISTERPLEX_CLKPIX_CEA24_H       = 3300;
localparam int MISTERPLEX_CLKPIX_CEA24_V       = 750;
localparam int MISTERPLEX_CLKPIX_CEA24_FPS     = 24;
localparam int MISTERPLEX_CLKPIX_CEA24_HZ      = 59_400_000;
localparam int MISTERPLEX_CLKPIX_CEA24_VIC     = 60;

// --- CEA-861 720p60 VIC4 (H1650) ---
localparam int MISTERPLEX_CLKPIX_CEA60_H       = 1650;
localparam int MISTERPLEX_CLKPIX_CEA60_V       = 750;
localparam int MISTERPLEX_CLKPIX_CEA60_HZ      = 74_250_000;
localparam int MISTERPLEX_CLKPIX_CEA60_VIC     = 4;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_M   = 297; // if ever on dedicated — not product
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_CEA60_PLL_C   = 20;

localparam int MISTERPLEX_CLKPIX_REF_HZ        = 50_000_000;
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
