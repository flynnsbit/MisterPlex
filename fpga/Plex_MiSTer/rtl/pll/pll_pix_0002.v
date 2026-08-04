`timescale 1ns/10ps
// Dedicated clk_pix PLL — OWN VCO so 29.700000 MHz is legal.
//
// Why not outclk_3 on pll_0002?
//   Shared integer-N VCO with 20 + 90 MHz forces VCO ∈ k*180 MHz.
//   180k / 29.7 integer ⇒ k multiple of 33 ⇒ min VCO = 5940 MHz (out of Cyclone V range).
//   Quartus 17.0.2 fit error on general[3] '29.7 MHz'; Info cited 30 MHz (VCO=900 family).
//
// Dedicated integer-N from 50 MHz:
//   M=297, N=10 → VCO = 50*(297/10) = 1485 MHz  (Cyclone V fPLL VCO 600–1600 MHz: IN RANGE)
//   C=50 → fout = 1485/50 = 29.700000 MHz  → H1650×V750 × 24.000 Hz EXACT
//   C=20 → fout = 1485/20 = 74.250000 MHz  (PRESENT_CLK_PIX_74_25, VIC-4 60 Hz)
//
// Default OFF: only elaborated when PRESENT_CLK_PIX_PLL. Instantiated from rtl/pll_pix.v.
// Do not put 29.7 back on pll_0002.

module pll_pix_0002 (
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire locked
);

`ifdef PRESENT_CLK_PIX_74_25
	// 720p60 VIC-4 — same VCO, C=20
	`define MISTERPLEX_PLL_PIX_FREQ "74.250000 MHz"
`else
	// PRODUCT compact 720p24: 1650*750*24 = 29_700_000 exact
	`define MISTERPLEX_PLL_PIX_FREQ "29.700000 MHz"
`endif

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0(`MISTERPLEX_PLL_PIX_FREQ),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("0 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
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
		.outclk(outclk_0),
		.locked(locked),
		.fboutclk(),
		.fbclk(1'b0),
		.refclk(refclk)
	);

endmodule
