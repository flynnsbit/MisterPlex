// Blackbox stubs for the two Altera vendor primitives that ship with Quartus
// and are therefore not tracked in this repository.  Used only by
// scripts/check_prefit_hierarchy.py so that `emu` can be elaborated outside
// Quartus.
//
// These are LEAVES.  Neither contains, or could contain, decode logic, so
// stubbing them cannot make an absent decode module look present.  That is the
// whole safety argument for this file and it is the only reason blackboxing is
// acceptable here: the check exists to answer "is module X in the elaborated
// hierarchy under emu", and a leaf stub cannot manufacture an X.
//
// If a future missing module is NOT a vendor leaf, do not add it here -- fix
// the file list instead.  check_prefit_hierarchy.py enforces that by refusing
// to blackbox anything outside its explicit allowlist.

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

module altera_pll #(
	parameter fractional_vco_multiplier = "false",
	parameter reference_clock_frequency = "0 MHz",
	parameter operation_mode = "direct",
	parameter number_of_clocks = 1,
	parameter output_clock_frequency0 = "0 MHz", parameter phase_shift0 = "0 ps", parameter duty_cycle0 = 50,
	parameter output_clock_frequency1 = "0 MHz", parameter phase_shift1 = "0 ps", parameter duty_cycle1 = 50,
	parameter output_clock_frequency2 = "0 MHz", parameter phase_shift2 = "0 ps", parameter duty_cycle2 = 50,
	parameter output_clock_frequency3 = "0 MHz", parameter phase_shift3 = "0 ps", parameter duty_cycle3 = 50,
	parameter output_clock_frequency4 = "0 MHz", parameter phase_shift4 = "0 ps", parameter duty_cycle4 = 50,
	parameter output_clock_frequency5 = "0 MHz", parameter phase_shift5 = "0 ps", parameter duty_cycle5 = 50,
	parameter output_clock_frequency6 = "0 MHz", parameter phase_shift6 = "0 ps", parameter duty_cycle6 = 50,
	parameter output_clock_frequency7 = "0 MHz", parameter phase_shift7 = "0 ps", parameter duty_cycle7 = 50,
	parameter output_clock_frequency8 = "0 MHz", parameter phase_shift8 = "0 ps", parameter duty_cycle8 = 50,
	parameter output_clock_frequency9 = "0 MHz", parameter phase_shift9 = "0 ps", parameter duty_cycle9 = 50,
	parameter output_clock_frequency10 = "0 MHz", parameter phase_shift10 = "0 ps", parameter duty_cycle10 = 50,
	parameter output_clock_frequency11 = "0 MHz", parameter phase_shift11 = "0 ps", parameter duty_cycle11 = 50,
	parameter output_clock_frequency12 = "0 MHz", parameter phase_shift12 = "0 ps", parameter duty_cycle12 = 50,
	parameter output_clock_frequency13 = "0 MHz", parameter phase_shift13 = "0 ps", parameter duty_cycle13 = 50,
	parameter output_clock_frequency14 = "0 MHz", parameter phase_shift14 = "0 ps", parameter duty_cycle14 = 50,
	parameter output_clock_frequency15 = "0 MHz", parameter phase_shift15 = "0 ps", parameter duty_cycle15 = 50,
	parameter output_clock_frequency16 = "0 MHz", parameter phase_shift16 = "0 ps", parameter duty_cycle16 = 50,
	parameter output_clock_frequency17 = "0 MHz", parameter phase_shift17 = "0 ps", parameter duty_cycle17 = 50,
	parameter pll_type = "General",
	parameter pll_subtype = "General"
) (
	input  wire        rst,
	input  wire        refclk,
	input  wire        fbclk,
	output wire [17:0] outclk,
	output wire        fboutclk,
	output wire        locked
);
	wire _unused_pll = &{1'b0, fbclk};
	assign outclk   = {18{refclk}};
	assign fboutclk = refclk;
	assign locked   = ~rst;
endmodule

module altddio_out #(
	parameter extend_oe_disable = "OFF",
	parameter intended_device_family = "Cyclone V",
	parameter invert_output = "OFF",
	parameter lpm_hint = "UNUSED",
	parameter lpm_type = "altddio_out",
	parameter oe_reg = "UNREGISTERED",
	parameter power_up_high = "OFF",
	parameter width = 1
) (
	input  wire [width-1:0] datain_h,
	input  wire [width-1:0] datain_l,
	input  wire             outclock,
	input  wire             outclocken,
	input  wire             aclr,
	input  wire             aset,
	input  wire             sclr,
	input  wire             sset,
	input  wire             oe,
	output wire [width-1:0] dataout
);
	wire _unused_ddio = &{1'b0, outclocken, aclr, aset, sclr, sset, oe};
	assign dataout = outclock ? datain_h : datain_l;
endmodule

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
