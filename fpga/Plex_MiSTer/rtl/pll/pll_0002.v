`timescale 1ns/10ps
// Source of truth for Plex fabric PLL (not the stale megawizard strings in pll.v).
// Product default: 3 clocks — clk_sys 20 / clk_sdram (macro) / clk_ddr 90.
// PRESENT_CLK_PIX_PLL (default OFF): 4th output clk_pix for 720p present.
//   - default pix: 30.000000 MHz  (PLL-legal; H1650×V750 → fps_eff=24.242424…)
//     29.700000 was ILLEGAL on this integer-N PLL (Quartus 17.0.2 fit error).
//   - PRESENT_CLK_PIX_EXACT24: 28.800000 MHz (H1600×V750 exact 24 — beam change req.)
//   - PRESENT_CLK_PIX_74_25: 74.250000 MHz (= 1650*750*60 — CEA-861 VIC 4 720p60)
// Never enable in product QSF without a parent-granted fit.
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0' — clk_sys
	output wire outclk_0,

	// interface 'outclk1' — clk_sdram
	output wire outclk_1,

	// interface 'outclk2' — clk_ddr
	output wire outclk_2,

`ifdef PRESENT_CLK_PIX_PLL
	// interface 'outclk3' — clk_pix (present scanout / CE_PIXEL domain)
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

// clk_pix frequency string (only consumed when PRESENT_CLK_PIX_PLL).
`ifdef PRESENT_CLK_PIX_74_25
`define MISTERPLEX_CLK_PIX_PLL_FREQ "74.250000 MHz"
`elsif PRESENT_CLK_PIX_EXACT24
// ALT exact-24: 28.8 MHz with H1600×V750 (not default beam).
`define MISTERPLEX_CLK_PIX_PLL_FREQ "28.800000 MHz"
`else
// PRODUCT: 30.000 MHz — only near-band value Quartus accepted (rejected 29.7).
// fps_eff @ H1650×V750 = 24.242424… Hz (+0.606 s/min vs true-24 content).
`define MISTERPLEX_CLK_PIX_PLL_FREQ "30.000000 MHz"
`endif

`ifdef PRESENT_CLK_PIX_PLL
	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("20.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("90.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3(`MISTERPLEX_CLK_PIX_PLL_FREQ),
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
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
`else
	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(3),
		.output_clock_frequency0("20.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("90.000000 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
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
		.outclk	({outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
`endif
endmodule
