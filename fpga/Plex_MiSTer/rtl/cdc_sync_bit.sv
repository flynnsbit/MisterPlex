// Single-bit level CDC: N-stage FF chain in destination clock domain.
// Multi-bit buses must NOT use this (torn samples). Use async_fifo / gray /
// req-ack with stable data instead.
//
// Synthesis: preserve chain so retiming/merging cannot collapse stages.
// Quartus 17: no SV-2012 default port values.

module cdc_sync_bit #(
	parameter int STAGES = 2
)(
	input  wire clk_dst,
	input  wire rst_dst,
	input  wire d_src,
	output wire q_dst
);
	// STAGES must be >= 2 for MTBF; elaboration check in sim only.
	// synthesis translate_off
	initial begin
		if (STAGES < 2)
			$error("cdc_sync_bit STAGES must be >= 2 (got %0d)", STAGES);
	end
	// synthesis translate_on

	(* preserve *) (* noprune *) reg [STAGES-1:0] sync_r;

	always @(posedge clk_dst) begin
		if (rst_dst)
			sync_r <= {STAGES{1'b0}};
		else
			sync_r <= {sync_r[STAGES-2:0], d_src};
	end

	assign q_dst = sync_r[STAGES-1];
endmodule
