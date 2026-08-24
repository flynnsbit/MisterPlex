// Testbench-only wrapper around product h264_deblock.sv. NOT synthesised.
`default_nettype none

module h264_deblock_tb (
	input  wire              clk,
	input  wire              reset,
	input  wire              pipe_valid_i,
	input  wire              is_chroma,
	input  wire [2:0]        bs_in,
	input  wire [5:0]        qp_avg,
	input  wire signed [4:0] alpha_off,
	input  wire signed [4:0] beta_off,
	input  wire [7:0]        p3_in [0:3],
	input  wire [7:0]        p2_in [0:3],
	input  wire [7:0]        p1_in [0:3],
	input  wire [7:0]        p0_in [0:3],
	input  wire [7:0]        q0_in [0:3],
	input  wire [7:0]        q1_in [0:3],
	input  wire [7:0]        q2_in [0:3],
	input  wire [7:0]        q3_in [0:3],
	input  wire              disable_all,
	input  wire              slice_boundary_blocked,
	input  wire              mb_boundary,
	input  wire              p_intra,
	input  wire              q_intra,
	input  wire              p_nonzero,
	input  wire              q_nonzero,
	input  wire [1:0]        p_ref,
	input  wire [1:0]        q_ref,
	input  wire signed [11:0] p_mvx,
	input  wire signed [11:0] p_mvy,
	input  wire signed [11:0] q_mvx,
	input  wire signed [11:0] q_mvy,
	output wire [2:0]        bs_derived,
	output wire              unsupported_ref,
	output wire [7:0]        p2_out [0:3],
	output wire [7:0]        p1_out [0:3],
	output wire [7:0]        p0_out [0:3],
	output wire [7:0]        q0_out [0:3],
	output wire [7:0]        q1_out [0:3],
	output wire [7:0]        q2_out [0:3],
	output wire [7:0]        alpha_dbg,
	output wire [7:0]        beta_dbg,
	output wire [5:0]        tc0_dbg,
	output wire              pipe_valid_o,
	output wire [7:0]        pipe_p2_out [0:3],
	output wire [7:0]        pipe_p1_out [0:3],
	output wire [7:0]        pipe_p0_out [0:3],
	output wire [7:0]        pipe_q0_out [0:3],
	output wire [7:0]        pipe_q1_out [0:3],
	output wire [7:0]        pipe_q2_out [0:3]
);
	h264_deblock_bs u_bs (
		.disable_all(disable_all),
		.slice_boundary_blocked(slice_boundary_blocked),
		.mb_boundary(mb_boundary),
		.p_intra(p_intra),
		.q_intra(q_intra),
		.p_nonzero(p_nonzero),
		.q_nonzero(q_nonzero),
		.p_ref(p_ref),
		.q_ref(q_ref),
		.p_mvx(p_mvx),
		.p_mvy(p_mvy),
		.q_mvx(q_mvx),
		.q_mvy(q_mvy),
		.bs(bs_derived),
		.unsupported_ref(unsupported_ref)
	);

	h264_deblock_edge u_edge (
		.is_chroma(is_chroma),
		.bs(bs_in),
		.qp_avg(qp_avg),
		.slice_alpha_c0_offset(alpha_off),
		.slice_beta_offset(beta_off),
		.p3_in(p3_in), .p2_in(p2_in), .p1_in(p1_in), .p0_in(p0_in),
		.q0_in(q0_in), .q1_in(q1_in), .q2_in(q2_in), .q3_in(q3_in),
		.p2_out(p2_out), .p1_out(p1_out), .p0_out(p0_out),
		.q0_out(q0_out), .q1_out(q1_out), .q2_out(q2_out),
		.alpha_dbg(alpha_dbg), .beta_dbg(beta_dbg), .tc0_dbg(tc0_dbg)
	);

	h264_deblock_edge_pipe u_edge_pipe (
		.clk(clk),
		.reset(reset),
		.valid_i(pipe_valid_i),
		.is_chroma(is_chroma),
		.bs(bs_in),
		.qp_avg(qp_avg),
		.slice_alpha_c0_offset(alpha_off),
		.slice_beta_offset(beta_off),
		.p3_in(p3_in), .p2_in(p2_in), .p1_in(p1_in), .p0_in(p0_in),
		.q0_in(q0_in), .q1_in(q1_in), .q2_in(q2_in), .q3_in(q3_in),
		.valid_o(pipe_valid_o),
		.p2_out(pipe_p2_out), .p1_out(pipe_p1_out), .p0_out(pipe_p0_out),
		.q0_out(pipe_q0_out), .q1_out(pipe_q1_out), .q2_out(pipe_q2_out)
	);

endmodule

`default_nettype wire
