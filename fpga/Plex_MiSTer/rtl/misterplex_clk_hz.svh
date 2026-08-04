// Single source of truth for fabric clock Hz (w-clock).
// Include after QSF macros are defined. Do not edit PLL strings without this.
// Product default: clk_sys 20 MHz. Optional:
//   CLK_SYS_24          → clk_sys 24_000_000 (L4 1312×762 @ ~24.006 Hz)
//   PRESENT_CLK_PIX_PLL → clk_pix 30_000_000 (PLL-legal; was illegal 29.7)
//                         fps_eff @ H1650×V750 = 24.242424… Hz (not exact 24)

`ifndef MISTERPLEX_CLK_HZ_SVH
`define MISTERPLEX_CLK_HZ_SVH

`ifdef CLK_SYS_24
	`define MISTERPLEX_CLK_SYS_HZ 24_000_000
	`define MISTERPLEX_CLK_SYS_MHZ_STR "24.000000 MHz"
`else
	`define MISTERPLEX_CLK_SYS_HZ 20_000_000
	`define MISTERPLEX_CLK_SYS_MHZ_STR "20.000000 MHz"
`endif

`ifdef PRESENT_CLK_PIX_PLL
	`ifdef PRESENT_CLK_PIX_74_25
		`define MISTERPLEX_CLK_PIX_HZ 74_250_000
		`define MISTERPLEX_CLK_PIX_MHZ_STR "74.250000 MHz"
	`elsif PRESENT_CLK_PIX_CEA24
		`define MISTERPLEX_CLK_PIX_HZ 59_400_000
		`define MISTERPLEX_CLK_PIX_MHZ_STR "59.400000 MHz"
	`elsif PRESENT_CLK_PIX_EXACT24
		// ALT: 28.8 MHz + H1600 (requires beam totals change — not default)
		`define MISTERPLEX_CLK_PIX_HZ 28_800_000
		`define MISTERPLEX_CLK_PIX_MHZ_STR "28.800000 MHz"
	`else
		// PRODUCT: PLL-legal 30.000 MHz (Quartus rejected 29.7 on this integer-N PLL)
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
// Product glass rate at 30 MHz: 30e6/(1650*750) = 24.242424… (not exact 24)
// MISTERPLEX_CEA720_F24_HZ = product clk_pix target (rate-match / need-faster gate)
`define MISTERPLEX_CEA720_F24_HZ 30_000_000
// Legacy name: exact-24 arithmetic used to claim 29.7 — ILLEGAL on this PLL
`define MISTERPLEX_CEA720_EXACT24_ILLEGAL_HZ 29_700_000
// CEA-861 720p60 VIC4: 1650*750*60 = 74_250_000
`define MISTERPLEX_CEA720_F60_HZ 74_250_000
// True CEA-861 720p24 VIC60: 3300*750*24 = 59_400_000
`define MISTERPLEX_CEA720_TRUE24_H_TOTAL 3300
`define MISTERPLEX_CEA720_TRUE24_HZ 59_400_000
// ALT exact-24 geometry (not default beam)
`define MISTERPLEX_CEA720_EXACT24_H_TOTAL 1600
`define MISTERPLEX_CEA720_EXACT24_HZ 28_800_000

// L4 compact raster (PLEX_PRESENT_720P_L4)
`define MISTERPLEX_L4_H_TOTAL 1312
`define MISTERPLEX_L4_V_TOTAL 762
`define MISTERPLEX_L4_PIX_FRAME (`MISTERPLEX_L4_H_TOTAL * `MISTERPLEX_L4_V_TOTAL)
// Exact: 1312*762*24 = 23_993_856
`define MISTERPLEX_L4_F24_HZ 23_993_856

// Peak Mpix/s production on clk_sys with PPC (MULTI path)
// Need >= product clk_pix (30 Mpix/s) for steady state.
`ifndef PRESENT_PX_PER_CLK
	`define MISTERPLEX_PRESENT_PPC 1
`else
	`define MISTERPLEX_PRESENT_PPC `PRESENT_PX_PER_CLK
`endif

`endif // MISTERPLEX_CLK_HZ_SVH
