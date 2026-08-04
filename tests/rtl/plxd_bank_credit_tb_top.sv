// Thin wrapper for Verilator
`default_nettype none
module plxd_bank_credit_tb_top (
	input  wire       clk,
	input  wire       reset,
	input  wire       vsync_pulse,
	input  wire       pending_ready,
	input  wire       claim_req,
	output wire       claim_ack,
	output wire       claim_bank,
	input  wire       doorbell_pulse,
	input  wire       doorbell_bank,
	output wire [1:0] free_bank_mask,
	output wire       disp_bank,
	output wire       swap_pending,
	output wire       pending_bank,
	output wire [15:0] frames_done,
	output wire       has_frame,
	output wire [1:0] filling_mask,
	output wire       err_doorbell_without_credit,
	output wire       err_double_claim
);
	plxd_bank_credit dut (
		.clk(clk),
		.reset(reset),
		.vsync_pulse(vsync_pulse),
		.pending_ready(pending_ready),
		.claim_req(claim_req),
		.claim_ack(claim_ack),
		.claim_bank(claim_bank),
		.doorbell_pulse(doorbell_pulse),
		.doorbell_bank(doorbell_bank),
		.free_bank_mask(free_bank_mask),
		.disp_bank(disp_bank),
		.swap_pending(swap_pending),
		.pending_bank(pending_bank),
		.frames_done(frames_done),
		.has_frame(has_frame),
		.filling_mask(filling_mask),
		.err_doorbell_without_credit(err_doorbell_without_credit),
		.err_double_claim(err_double_claim)
	);
endmodule
`default_nettype wire
