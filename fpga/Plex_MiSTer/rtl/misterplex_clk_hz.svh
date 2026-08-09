// Single source of truth for fabric clock Hz (w-clock).
// Include after QSF macros are defined. Do not edit PLL strings without this.
// Product default: clk_sys 20 MHz. Optional:
//   CLK_SYS_24          → clk_sys 24_000_000 (L4 1312×762 @ ~24.006 Hz)
//   PRESENT_CLK_PIX_PLL → clk_pix 29_700_000 (or 74_250_000 with PRESENT_CLK_PIX_74_25)

`ifndef MISTERPLEX_CLK_HZ_SVH
`define MISTERPLEX_CLK_HZ_SVH

`ifdef CLK_SYS_40
	// LAB: integer-N legal ~39.375 MHz for 720p60 + PPC=2 (78.75 Mpix/s peak).
	`define MISTERPLEX_CLK_SYS_HZ 39_375_000
	`define MISTERPLEX_CLK_SYS_MHZ_STR "39.375000 MHz"
`elsif CLK_SYS_30
	// Product crawl fix: sys=pix=30 MHz → no present async CDC; glass ~24.24 Hz
	// at H1650×V750 with CE every clk. Same PLL string as old compact pix.
	`define MISTERPLEX_CLK_SYS_HZ 30_000_000
	`define MISTERPLEX_CLK_SYS_MHZ_STR "30.000000 MHz"
`elsif CLK_SYS_24
	`define MISTERPLEX_CLK_SYS_HZ 24_000_000
	`define MISTERPLEX_CLK_SYS_MHZ_STR "24.000000 MHz"
`else
	`define MISTERPLEX_CLK_SYS_HZ 20_000_000
	`define MISTERPLEX_CLK_SYS_MHZ_STR "20.000000 MHz"
`endif

`ifdef PRESENT_CLK_PIX_PLL
	`ifdef PRESENT_CLK_PIX_74_25
		// Match pll_0002 integer-N legal neighbor (not ideal 74.25).
		`define MISTERPLEX_CLK_PIX_HZ 74_117_647
		`define MISTERPLEX_CLK_PIX_MHZ_STR "74.117647 MHz"
	`elsif PRESENT_CLK_PIX_30
		// Match pll_0002 legal neighbor (~29.95 Hz @ H1650 V750).
		`define MISTERPLEX_CLK_PIX_HZ 37_058_823
		`define MISTERPLEX_CLK_PIX_MHZ_STR "37.058823 MHz"
	`elsif PRESENT_CLK_PIX_CEA24
		`define MISTERPLEX_CLK_PIX_HZ 59_400_000
		`define MISTERPLEX_CLK_PIX_MHZ_STR "59.400000 MHz"
	`else
		// COMPACT H1650@24 — product uses 30.0 MHz PLL string (24.24 Hz glass).
		// Rate-match / honesty numbers still quote ideal 29.7; PLL is 30.0.
		`define MISTERPLEX_CLK_PIX_HZ 30_000_000
		`define MISTERPLEX_CLK_PIX_MHZ_STR "30.000000 MHz"
	`endif
`else
	// No separate pix PLL: pixel domain = clk_sys
	`define MISTERPLEX_CLK_PIX_HZ `MISTERPLEX_CLK_SYS_HZ
	`define MISTERPLEX_CLK_PIX_MHZ_STR `MISTERPLEX_CLK_SYS_MHZ_STR
`endif

// Fabric COMPACT 720p totals (PRESENT_MULTI_PIXEL default beam H=1650).
// NOT CEA-861 720p24 (VIC60 is H=3300 @ 59.4 MHz — see misterplex_clk_pix_recipe.svh).
`define MISTERPLEX_CEA720_H_TOTAL 1650
`define MISTERPLEX_CEA720_V_TOTAL 750
`define MISTERPLEX_CEA720_PIX_FRAME (`MISTERPLEX_CEA720_H_TOTAL * `MISTERPLEX_CEA720_V_TOTAL)
// Compact 24 fps: 1650*750*24 = 29_700_000 (ascal input raster — not CEA VIC60)
`define MISTERPLEX_CEA720_F24_HZ 29_700_000
// CEA-861 720p60 VIC4: 1650*750*60 = 74_250_000
`define MISTERPLEX_CEA720_F60_HZ 74_250_000
// True CEA-861 720p24 VIC60: 3300*750*24 = 59_400_000
`define MISTERPLEX_CEA720_TRUE24_H_TOTAL 3300
`define MISTERPLEX_CEA720_TRUE24_HZ 59_400_000

// L4 compact raster (PLEX_PRESENT_720P_L4)
`define MISTERPLEX_L4_H_TOTAL 1312
`define MISTERPLEX_L4_V_TOTAL 762
`define MISTERPLEX_L4_PIX_FRAME (`MISTERPLEX_L4_H_TOTAL * `MISTERPLEX_L4_V_TOTAL)
// Exact: 1312*762*24 = 23_993_856
`define MISTERPLEX_L4_F24_HZ 23_993_856

// Peak Mpix/s production on clk_sys with PPC (MULTI path)
// Need >= CEA 29.7 for 24 fps steady state.
`ifndef PRESENT_PX_PER_CLK
	`define MISTERPLEX_PRESENT_PPC 1
`else
	`define MISTERPLEX_PRESENT_PPC `PRESENT_PX_PER_CLK
`endif

`endif // MISTERPLEX_CLK_HZ_SVH
