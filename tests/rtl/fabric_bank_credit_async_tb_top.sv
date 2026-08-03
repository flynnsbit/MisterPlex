// fabric_bank_credit async producer TB: chunked fill, NEG doorbell-before-visible.
`default_nettype none
module fabric_bank_credit_async_tb_top (
	input  wire       clk,
	input  wire       reset,
	input  wire       vsync_swap,
	input  wire       claim_req,
	output wire       claim_ack,
	output wire [1:0] claim_bank,
	input  wire       commit_pulse,
	input  wire [1:0] commit_bank,
	input  wire       ext_payload_visible_pulse,
	input  wire [1:0] ext_visible_bank,
	input  wire       ext_doorbell_pulse,
	input  wire [1:0] ext_doorbell_bank,
	output wire [1:0] free_mask,
	output wire [1:0] filling_mask,
	output wire [1:0] visible_mask,
	output wire       swap_pending,
	output wire       disp_bank,
	output wire [15:0] frames_done,
	output wire       err_doorbell_before_visible,
	output wire       err_doorbell_without_credit
);
	fabric_bank_credit u (
		.clk(clk), .reset(reset), .vsync_swap(vsync_swap),
		.claim_req(claim_req), .claim_ack(claim_ack), .claim_bank(claim_bank),
		.commit_pulse(commit_pulse), .commit_bank(commit_bank),
		.ext_payload_visible_pulse(ext_payload_visible_pulse),
		.ext_visible_bank(ext_visible_bank),
		.ext_doorbell_pulse(ext_doorbell_pulse),
		.ext_doorbell_bank(ext_doorbell_bank),
		.free_mask(free_mask), .disp_bank(disp_bank),
		.swap_pending(swap_pending), .pending_bank(),
		.frames_done(frames_done),
		.filling_mask(filling_mask), .visible_mask(visible_mask),
		.err_doorbell_before_visible(err_doorbell_before_visible),
		.err_doorbell_without_credit(err_doorbell_without_credit),
		.next_free_bank(), .any_free()
	);
endmodule
`default_nettype wire
