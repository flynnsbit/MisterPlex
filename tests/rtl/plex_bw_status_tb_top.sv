// Elab + cycle smoke for plex_bw_status (w-clock BW SoT stamp).
`timescale 1ns/1ps

module plex_bw_status_tb_top (
	input  wire        clk,
	output wire [31:0] dir_bps,
	output wire [17:0] beats,
	output wire [18:0] rw_pair,
	output wire [7:0]  ppc,
	output wire        nack_de,
	output wire [15:0] t_copy_us,
	output wire [15:0] budget_us
);
	plex_bw_status u_dut (
		.clk(clk),
		.bw_dir_b_per_s(dir_bps),
		.bw_beats_per_frame(beats),
		.bw_beats_rw_pair(rw_pair),
		.bw_product_ppc(ppc),
		.bw_nack_de_peak_is_not_ddr(nack_de),
		.bw_t_copy_arm_us(t_copy_us),
		.bw_frame_budget_us(budget_us)
	);
endmodule
