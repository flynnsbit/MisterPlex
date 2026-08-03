`timescale 1ns/10ps
// Product PLL SoT. PRESENT_CLK_PIX_PLL (default OFF) adds outclk_3 @ 29.7 MHz
// as clk_pix. Shipping/default keeps number_of_clocks=3, fractional=false —
// bit-identical intent to proven cores when the macro is unset.
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

`ifdef PRESENT_CLK_PIX_PLL
	// interface 'outclk3' — clk_pix (CEA 720p24 pixel rate)
	output wire outclk_3,
`endif

	// interface 'locked'
	output wire locked
);

`ifdef SDRAM_CLK_142
`define MISTERPLEX_SDRAM_PLL_FREQ "142.000000 MHz"
`elsif SDRAM_CLK_133
`define MISTERPLEX_SDRAM_PLL_FREQ "133.333333 MHz"
`elsif SDRAM_CLK_120
`define MISTERPLEX_SDRAM_PLL_FREQ "120.000000 MHz"
`elsif SDRAM_CLK_110
`define MISTERPLEX_SDRAM_PLL_FREQ "110.000000 MHz"
`elsif SDRAM_CLK_80
`define MISTERPLEX_SDRAM_PLL_FREQ "80.000000 MHz"
`elsif SDRAM_CLK_75
`define MISTERPLEX_SDRAM_PLL_FREQ "75.000000 MHz"
`elsif SDRAM_CLK_50
`define MISTERPLEX_SDRAM_PLL_FREQ "50.000000 MHz"
`else
`define MISTERPLEX_SDRAM_PLL_FREQ "100.000000 MHz"
`endif

	altera_pll #(
`ifdef PRESENT_CLK_PIX_PLL
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
`else
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
`endif
		.output_clock_frequency0("20.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("90.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
`ifdef PRESENT_CLK_PIX_PLL
		.output_clock_frequency3("29.700000 MHz"),
`else
		.output_clock_frequency3("0 MHz"),
`endif
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
`ifdef PRESENT_CLK_PIX_PLL
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
`else
		.outclk	({outclk_2, outclk_1, outclk_0}),
`endif
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
