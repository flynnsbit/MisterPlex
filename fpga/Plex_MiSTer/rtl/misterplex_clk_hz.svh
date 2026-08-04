// Single source of truth for fabric clock Hz (w-clock).
// Include after QSF macros are defined. Do not edit PLL strings without this.
// Product default: clk_sys 20 MHz. Optional:
//   CLK_SYS_24          → clk_sys 24_000_000 (L4 1312×762 @ ~24.006 Hz)
//   PRESENT_CLK_PIX_PLL → clk_pix 29_700_000 (or 74_250_000 with PRESENT_CLK_PIX_74_25)

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
	`else
		`define MISTERPLEX_CLK_PIX_HZ 29_700_000
		`define MISTERPLEX_CLK_PIX_MHZ_STR "29.700000 MHz"
	`endif
`else
	// No separate pix PLL: pixel domain = clk_sys
	`define MISTERPLEX_CLK_PIX_HZ `MISTERPLEX_CLK_SYS_HZ
	`define MISTERPLEX_CLK_PIX_MHZ_STR `MISTERPLEX_CLK_SYS_MHZ_STR
`endif

// CEA-861 720p totals (PRESENT_MULTI_PIXEL beam)
`define MISTERPLEX_CEA720_H_TOTAL 1650
`define MISTERPLEX_CEA720_V_TOTAL 750
`define MISTERPLEX_CEA720_PIX_FRAME (`MISTERPLEX_CEA720_H_TOTAL * `MISTERPLEX_CEA720_V_TOTAL)

// L4 compact raster (PLEX_PRESENT_720P_L4)
`define MISTERPLEX_L4_H_TOTAL 1312
`define MISTERPLEX_L4_V_TOTAL 762
`define MISTERPLEX_L4_PIX_FRAME (`MISTERPLEX_L4_H_TOTAL * `MISTERPLEX_L4_V_TOTAL)

// Peak Mpix/s production on clk_sys with PPC (MULTI path)
// Need >= CEA 29.7 for 24 fps steady state.
`ifndef PRESENT_PX_PER_CLK
	`define MISTERPLEX_PRESENT_PPC 1
`else
	`define MISTERPLEX_PRESENT_PPC `PRESENT_PX_PER_CLK
`endif

`endif // MISTERPLEX_CLK_HZ_SVH
