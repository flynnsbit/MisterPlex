// fabric_bank_credit — dual-bank free_mask / claim / commit (w-mem).
//
// Agrees with w-path host_bank_ingest_credit + ddr_zero_copy_ingest ordering:
//   credit (free_mask) → exclusive claim/fill → payload_visible → doorbell/commit
//   → vsync retire frees old disp. Never scan a bank mid-fill.
//
// Internal fabric_ddr_writer: claim → fill+drain → commit_pulse (= doorbell done).
// External async (PL330): claim → chunks → payload_visible_pulse → doorbell_pulse.
// Doorbell before payload_visible is sticky-error (tearing class).
//
// Macro FABRIC_DDR_WRITER default OFF.
//
`default_nettype none

module fabric_bank_credit (
	input  wire       clk,
	input  wire       reset,

	input  wire       vsync_swap,

	// Exclusive claim (fabric or host bridge)
	input  wire       claim_req,
	output reg        claim_ack,
	output reg  [1:0] claim_bank,

	// Internal writer path: single pulse after drain+doorbell ordered
	input  wire       commit_pulse,
	input  wire [1:0] commit_bank,

	// External async path (PL330 / HPS) — optional; leave 0 if unused
	input  wire       ext_payload_visible_pulse,
	input  wire [1:0] ext_visible_bank,
	input  wire       ext_doorbell_pulse,
	input  wire [1:0] ext_doorbell_bank,

	output reg  [1:0] free_mask,
	output reg        disp_bank,
	output reg        swap_pending,
	output reg        pending_bank,
	output reg [15:0] frames_done,

	// Mid-fill mask: claimed, not yet doorbell-committed
	output reg  [1:0] filling_mask,
	// Visible but doorbell not yet rung (ext path)
	output reg  [1:0] visible_mask,

	output reg        err_doorbell_before_visible,
	output reg        err_doorbell_without_credit,

	output wire [1:0] next_free_bank,
	output wire       any_free
);
	wire free0 = free_mask[0];
	wire free1 = free_mask[1];
	assign any_free = |free_mask;
	assign next_free_bank = free0 ? 2'd0 : (free1 ? 2'd1 : 2'd3);

	(* keep = 1 *) wire [31:0] plxd_hi_keep = {
		frames_done,
		8'd0,
		err_doorbell_before_visible,
		err_doorbell_without_credit,
		visible_mask,
		filling_mask,
		swap_pending,
		disp_bank,
		free_mask
	};

	wire [1:0] cbank = commit_bank;
	wire [1:0] vbank = ext_visible_bank;
	wire [1:0] dbank = ext_doorbell_bank;

	always @(posedge clk) begin
		if (reset) begin
			disp_bank     <= 1'b0;
			pending_bank  <= 1'b0;
			swap_pending  <= 1'b0;
			free_mask     <= 2'b10;
			frames_done   <= 16'd0;
			claim_ack     <= 1'b0;
			claim_bank    <= 2'd0;
			filling_mask  <= 2'b00;
			visible_mask  <= 2'b00;
			err_doorbell_before_visible <= 1'b0;
			err_doorbell_without_credit <= 1'b0;
		end else begin
			claim_ack <= 1'b0;

			// Claim: exclusive take of one free bank → filling
			if (claim_req && any_free && !claim_ack) begin
				claim_bank <= next_free_bank;
				claim_ack  <= 1'b1;
				if (next_free_bank == 2'd0) begin
					free_mask[0]    <= 1'b0;
					filling_mask[0] <= 1'b1;
				end else if (next_free_bank == 2'd1) begin
					free_mask[1]    <= 1'b0;
					filling_mask[1] <= 1'b1;
				end
			end

			// External: payload fully visible (DMA done / barrier)
			if (ext_payload_visible_pulse) begin
				if (filling_mask[vbank[0]]) begin
					filling_mask[vbank[0]] <= 1'b0;
					visible_mask[vbank[0]] <= 1'b1;
				end
			end

			// External doorbell — require visible_mask (NEG if still filling)
			if (ext_doorbell_pulse) begin
				if (!visible_mask[dbank[0]] && !filling_mask[dbank[0]])
					err_doorbell_without_credit <= 1'b1;
				if (filling_mask[dbank[0]] || !visible_mask[dbank[0]])
					err_doorbell_before_visible <= 1'b1;
				else begin
					visible_mask[dbank[0]] <= 1'b0;
					pending_bank <= dbank[0];
					swap_pending <= 1'b1;
					free_mask    <= 2'b00;
				end
			end

			// Internal writer commit: drain+doorbell already ordered in writer
			if (commit_pulse) begin
				filling_mask[cbank[0]] <= 1'b0;
				visible_mask[cbank[0]] <= 1'b0;
				pending_bank <= cbank[0];
				swap_pending <= 1'b1;
				free_mask    <= 2'b00;
			end

			// Vsync swap: pending → disp; old disp free
			if (vsync_swap && swap_pending) begin
				free_mask    <= (2'b01 << disp_bank);
				disp_bank    <= pending_bank;
				swap_pending <= 1'b0;
				frames_done  <= frames_done + 16'd1;
			end
		end
	end
endmodule

`default_nettype wire
