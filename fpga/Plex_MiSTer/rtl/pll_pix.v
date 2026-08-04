// Dedicated clk_pix PLL wrapper. Frequency SoT: rtl/pll/pll_pix_0002.v
// Only used under PRESENT_CLK_PIX_PLL (default OFF). Does not touch pll_0002.
`timescale 1 ps / 1 ps
module pll_pix (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);
	pll_pix_0002 pll_pix_inst (
		.refclk(refclk),
		.rst(rst),
		.outclk_0(outclk_0),
		.locked(locked)
	);
endmodule
