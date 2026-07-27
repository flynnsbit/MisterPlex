// RTL-in-the-loop reconstruction scorer.
// Instantiates the actual dequant/IDCT/recon pipeline and exposes
// coefficient/prediction injection ports for the C++ testbench driver.
// This tests whether the FPGA arithmetic produces correct output
// for known golden inputs — independent of CAVLC parsing or prediction.

module h264_rtl_recon_scorer_tb #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240
)(
	input  wire        clk,
	input  wire        reset,

	// Testbench injection: coefficients + QP + prediction for one 4x4 block
	input  wire signed [8:0]  inject_coeff [0:15],
	input  wire [5:0]         inject_qp,
	input  wire [7:0]         inject_pred [0:15],
	input  wire               inject_valid,

	// RTL reconstruction output
	output wire [7:0]         recon_out [0:15],
	output wire               recon_ready,

	// Pipeline visibility for degeneracy checks
	output wire signed [17:0] dequant_out [0:15],
	output wire signed [17:0] idct_out [0:15]
);

	// Dequant stage
	wire signed [17:0] dq [0:15];
	h264_dequant4x4 u_dequant (
		.coeff(inject_coeff),
		.qp(inject_qp),
		.max_coeff(5'd16),
		.dequant(dq)
	);

	// IDCT stage
	wire signed [17:0] res [0:15];
	h264_idct4x4 u_idct (
		.dequant(dq),
		.residual(res)
	);

	// Reconstruction stage (pred + residual, clipped to [0,255])
	wire [7:0] rec [0:15];
	h264_recon4x4 u_recon (
		.pred(inject_pred),
		.residual(res),
		.recon(rec)
	);

	assign recon_out = rec;
	assign dequant_out = dq;
	assign idct_out = res;

	// Combinational: output ready same cycle as input valid
	assign recon_ready = inject_valid;

endmodule
