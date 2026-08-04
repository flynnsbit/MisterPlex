// Top for plex_rbf_build_id Verilator TB — healthy + FAULT_ZERO_STAMP twin.
`timescale 1ns / 1ps

module plex_rbf_build_id_tb_top (
	input  wire        clk,
	input  wire        reset,
	output wire [63:0] build_id_good,
	output wire        id_valid_good,
	output wire        stamp_alive_good,
	output wire [63:0] build_id_fault,
	output wire        id_valid_fault,
	output wire        stamp_alive_fault,
	// 1 when fault twin is correctly dead (valid=0 and magic cleared)
	output wire        fault_alive_is_zero
);

	plex_rbf_build_id #(
		.MAGIC(32'h504C5842),
		.COMMIT_PREFIX(32'h0139F2C5),
		.GIT_DIRTY(1'b0),
		.QIP_COUNT(16'd19),
		.FAULT_ZERO_STAMP(1'b0)
	) u_good (
		.clk(clk),
		.reset(reset),
		.build_id(build_id_good),
		.id_valid(id_valid_good),
		.stamp_alive(stamp_alive_good)
	);

	plex_rbf_build_id #(
		.MAGIC(32'h504C5842),
		.COMMIT_PREFIX(32'h0139F2C5),
		.GIT_DIRTY(1'b0),
		.QIP_COUNT(16'd19),
		.FAULT_ZERO_STAMP(1'b1)
	) u_fault (
		.clk(clk),
		.reset(reset),
		.build_id(build_id_fault),
		.id_valid(id_valid_fault),
		.stamp_alive(stamp_alive_fault)
	);

	// Fault twin: id_valid must be 0; build_id must be 0 after settle.
	assign fault_alive_is_zero = (id_valid_fault == 1'b0) && (build_id_fault == 64'd0);

endmodule
