// Wrapper only. Frequency SoT is rtl/pll/pll_0002.v (edit that file).
// Product: outclk_0 = clk_sys 20 MHz (PRESENT_CLK_SYS_24 → 24 MHz, default OFF).
// outclk_1 = SDRAM; outclk_2 = DDRAM bridge 90 MHz. No 4th fabric clock.

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk — clk_sys
		output wire  outclk_1, // outclk1.clk — SDRAM controller clock
		output wire  outclk_2, // outclk2.clk — DDRAM bridge clock 90 MHz
		output wire  locked    //  locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.locked   (locked)
	);

endmodule
