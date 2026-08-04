`timescale 1ns/10ps
// Source of truth for Plex fabric PLL (not the stale megawizard strings in pll.v).
//
// PRODUCT clk_pix (PRESENT_CLK_PIX_PLL): 28.800000 MHz on outclk_3.
//   1600 × 750 × 24 = 28_800_000 EXACT → fps_eff = 24.000 Hz.
// Shared integer-N VCO with 20 + 90:
//   VCO = 720 MHz (M=72 N=5 from 50 MHz ref; PFD = 10 MHz ≥ 5 MHz min)
//   C20  = 720/20   = 36
//   C90  = 720/90   = 8
//   Cpix = 720/28.8 = 25
// Alt VCO 1440: C20=72, C90=16, Cpix=50 (also legal).
//
// 29.7 MHz is ILLEGAL on this shared VCO (min VCO 5940 MHz) — never select it.
// 30 MHz @ H1650 was a false product (24.242 Hz judder) — retired.
//
// SDRAM constraint (record): QSF may set 142 MHz, but with 20+90+28.8 the live
// family is VCO multiples of lcm-compatible counters. 120 MHz works (720/120=6).
// 142 MHz does not share VCO 720 with 20/90/28.8. Today DDR_FRAME_STORE prunes
// SDRAM outclk; do not re-enable 142 without a new PLL plan.

module  pll_0002(
	input wire refclk,
	input wire rst,
	output wire outclk_0, // clk_sys 20 MHz
	output wire outclk_1, // clk_sdram (macro; often pruned)
	output wire outclk_2, // clk_ddr 90 MHz
`ifdef PRESENT_CLK_PIX_PLL
	output wire outclk_3, // clk_pix 28.800000 MHz product
`endif
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

// clk_pix frequency (only when PRESENT_CLK_PIX_PLL)
`ifdef PRESENT_CLK_PIX_74_25
	// VIC-4 60 Hz — out of scope unless parent grants
	`define MISTERPLEX_CLK_PIX_PLL_FREQ "74.250000 MHz"
`else
	// PRODUCT exact-24: 1600*750*24 = 28.800000 MHz (shared VCO 720 family)
	`define MISTERPLEX_CLK_PIX_PLL_FREQ "28.800000 MHz"
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
		.rst(rst),
		.outclk({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked(locked),
		.fboutclk( ),
		.fbclk(1'b0),
		.refclk(refclk)
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
		.rst(rst),
		.outclk({outclk_2, outclk_1, outclk_0}),
		.locked(locked),
		.fboutclk( ),
		.fbclk(1'b0),
		.refclk(refclk)
	);
`endif

endmodule
