// Wrapper only. Frequency SoT is rtl/pll/pll_0002.v (edit that file).
// PRESENT_CLK_PIX_PLL: outclk_3 = 28.800000 MHz (exact 24.000 @ H1600×V750).

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0, // clk_sys 20 MHz
		output wire  outclk_1, // SDRAM
		output wire  outclk_2, // clk_ddr 90 MHz
`ifdef PRESENT_CLK_PIX_PLL
		output wire  outclk_3, // clk_pix 28.800000 MHz
`endif
		output wire  locked
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
`ifdef PRESENT_CLK_PIX_PLL
		.outclk_3 (outclk_3),
`endif
		.locked   (locked)
	);

endmodule
