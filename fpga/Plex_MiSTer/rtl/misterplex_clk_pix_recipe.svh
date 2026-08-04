// misterplex_clk_pix_recipe.svh — 720p pixel-clock recipe (w-clock).
// MODULE-LOCAL include OK for localparams; prefer once per module.
//
// PRODUCT FRAME RATE is 24 fps (PMS / parent 720p24), NOT 60.
// Do not assume VIC-4 74.25 MHz is the product target.
//
// Exact pixel rates from CEA-861 720p blanking totals H=1650 V=750:
//   F24 = 1650 * 750 * 24 = 29_700_000 Hz   ← PRODUCT default when PRESENT_CLK_PIX_PLL
//   F60 = 1650 * 750 * 60 = 74_250_000 Hz   ← optional PRESENT_CLK_PIX_74_25 only
//
// L4 compact alternative (no separate clk_pix required if CLK_SYS_24):
//   1312 * 762 * 24 = 23_993_856 Hz ≈ clk_sys@24
//
// PLL SoT: fpga/Plex_MiSTer/rtl/pll/pll_0002.v  (NOT stale pll.v megawizard strings)
//   refclk = 50.0 MHz (CLK_50M)
//   outclk_0 clk_sys 20.000 (or 24 with CLK_SYS_24)
//   outclk_2 clk_ddr 90.000
//   outclk_3 clk_pix 29.700 (or 74.250) when PRESENT_CLK_PIX_PLL
//   fractional_vco_multiplier("false") — integer-N mode
//
// Exact integer M/N/C solutions from 50 MHz (VCO in Cyclone V ~600–1600 MHz band):
//   29.70 MHz: M=297 N=10 C=50 → VCO=1485 MHz; also M=297 N=20 C=25 → VCO=742.5
//   74.25 MHz: M=297 N=10 C=20 → VCO=1485 MHz; also M=297 N=20 C=10 → VCO=742.5
// ⇒ requested frequency is EXACTLY synthesizable (0 ppm) if Quartus picks such counters.
// Actual counters are UNKNOWN until a fit reports PLL "Actual" settings — do not claim
// fitted ppm without that artifact.
//
// pll_hdmi (sys/): SEPARATE PLL, fractional, typically 148.5 MHz TMDS domain + pll_hdmi_adj.
// Enabling PRESENT_CLK_PIX_PLL does NOT reconfigure pll_hdmi RTL. It only:
//   - adds emu pll outclk_3
//   - drives present_core.clk_pix and CLK_VIDEO (Plex.sv)
// ascal/video_mixer still sit on CLK_VIDEO; HDMI PLL remains the phy domain.
//
// MULTI without clk_pix PLL: PPC=2 @ clk_sys 20 → peak 40 Mpix/s ≥ 29.7 with
// present_pix_rate_match throttle (alternate path; still needs FRAME 1280×720 recipe).
//
// DEFAULT OFF in product QSF. Parent fit grant required. Source Plex_clk_pix.sdc with enable.
//
// Post-strip STA (parent nostub-poststrip1, clk_pix OFF — not a clk_pix measurement):
//   general[2] clk_ddr slack +0.311 ns (worst)
//   general[0] clk_sys slack +1.290 ns
//   pll_hdmi slack +0.571 ns
// Enabling clk_pix adds a NEW domain; its Fmax/slack is UNKNOWN until that fit.
// Thin +0.311 is on clk_ddr — fabric DMA / heavier DDR traffic is the risk surface there,
// not a direct "pixel clock eats sys slack" claim.

// Exact products (gates / status stamps)
localparam int MISTERPLEX_CLKPIX_CEA_H       = 1650;
localparam int MISTERPLEX_CLKPIX_CEA_V       = 750;
localparam int MISTERPLEX_CLKPIX_FPS_24      = 24;
localparam int MISTERPLEX_CLKPIX_FPS_60      = 60;
localparam int MISTERPLEX_CLKPIX_F24_HZ      = 29_700_000; // 1650*750*24
localparam int MISTERPLEX_CLKPIX_F60_HZ      = 74_250_000; // 1650*750*60
localparam int MISTERPLEX_CLKPIX_REF_HZ      = 50_000_000;
// Documented integer solution (29.7): M/N/C
localparam int MISTERPLEX_CLKPIX_F24_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_F24_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_F24_PLL_C   = 50;
localparam int MISTERPLEX_CLKPIX_F60_PLL_M   = 297;
localparam int MISTERPLEX_CLKPIX_F60_PLL_N   = 10;
localparam int MISTERPLEX_CLKPIX_F60_PLL_C   = 20;
// Product intent: 24 fps path
localparam int MISTERPLEX_CLKPIX_PRODUCT_HZ  = MISTERPLEX_CLKPIX_F24_HZ;
