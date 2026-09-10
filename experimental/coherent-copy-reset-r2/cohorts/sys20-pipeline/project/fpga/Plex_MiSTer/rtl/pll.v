// Base PLL requests live in rtl/pll/pll_0002.v.
// SYS85 adds an independent system PLL; it cannot share the DDR90 VCO.
// PRESENT_CLK_PIX_PLL adds outclk_3 = clk_pix (default OFF).

`timescale 1 ps / 1 ps
`include "plex_performance_clock.svh"
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk — selected system clock
		output wire  outclk_1, // outclk1.clk — SDRAM controller clock
		output wire  outclk_2, // outclk2.clk — DDRAM bridge clock 90 MHz
`ifdef PRESENT_CLK_PIX_PLL
		output wire  outclk_3, // outclk3.clk — clk_pix (CEA 720p present)
`endif
		output wire  locked    //  locked.export
	);

`ifdef PLEX_CLK_SYS_85
	wire base_locked, sys_locked;
	wire base_clk20;
	assign locked = base_locked & sys_locked;

	// 85 and 90 MHz need separate VCOs: lcm(85,90)=1530 MHz > 800 MHz.
	// Legal integer SYS solution: 50 MHz * M34 / N5 = 340 MHz, C4 = 85 MHz.
	// Keep both PLLs referenced to the same 50 MHz input and fully timed.
	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0(`PLEX_PERF_SYS_PLL),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.pll_type("General"),
		.pll_subtype("General")
	) sys85_pll (
		.refclk(refclk), .rst(rst), .outclk(outclk_0),
		.locked(sys_locked), .fboutclk(), .fbclk(1'b0)
	);
`endif

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
`ifdef PLEX_CLK_SYS_85
		.outclk_0 (base_clk20),
`else
		.outclk_0 (outclk_0),
`endif
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
`ifdef PRESENT_CLK_PIX_PLL
		.outclk_3 (outclk_3),
`endif
`ifdef PLEX_CLK_SYS_85
		.locked   (base_locked)
`else
		.locked   (locked)
`endif
	);

endmodule
