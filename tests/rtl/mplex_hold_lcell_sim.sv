// Sim-only wire-through for mplex_hold_lcell (product def lives in ddr_frame_store.sv).
// Used by fabric-publish unit sims that compile arbiter3 without the store.
// Quartus product netlist does NOT list this file in files.qip.
`ifndef MPLEX_HOLD_LCELL_DEFINED
`define MPLEX_HOLD_LCELL_DEFINED
module mplex_hold_lcell (
	input  wire din,
	output wire dout
);
	assign dout = din;
endmodule
`endif
