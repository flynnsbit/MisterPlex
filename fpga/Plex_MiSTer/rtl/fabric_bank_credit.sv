// fabric_bank_credit — dual-bank free_mask / claim / commit (w-mem).
//
// Mirrors product PLXD semantics (mailbox_abi_spec.hpp) so fabric writer and
// external DMA (PL330 / ARM) share one contract with the scanout reader
// (w-scaler owns read of the same banks):
//
//   free_mask bit i = 1  → producer may fill bank i
//   claim(bank)          → clear free bit (exclusive fill)
//   commit(bank)         → payload+doorbell done; bank becomes pending display
//   vsync_swap           → pending becomes disp; old disp returns to free
//
// Corruption class (rd-duck): never claim/commit the bank that is disp while
// scanout is live — free_mask enforces that. swap_pending ⇒ free_mask=0.
//
// Macro FABRIC_DDR_WRITER default OFF.
//
`default_nettype none

module fabric_bank_credit (
	input  wire       clk,
	input  wire       reset,

	// Scanout domain event (already synced to clk if needed)
	input  wire       vsync_swap,   // pulse: present flipped to pending bank

	// Producer claim/commit (fabric writer or external via fabric bridge)
	input  wire       claim_req,
	output reg        claim_ack,
	output reg  [1:0] claim_bank,   // bank granted (valid with claim_ack)
	input  wire       commit_pulse, // after last payload + doorbell ordered
	input  wire [1:0] commit_bank,

	// PLXD-compatible status (combinational + registered publish)
	output reg  [1:0] free_mask,
	output reg        disp_bank,
	output reg        swap_pending,
	output reg        pending_bank,
	output reg [15:0] frames_done,

	// Convenience: next free bank or 2'b11 if none
	output wire [1:0] next_free_bank,
	output wire       any_free
);
	wire free0 = free_mask[0];
	wire free1 = free_mask[1];
	assign any_free = |free_mask;
	assign next_free_bank = free0 ? 2'd0 : (free1 ? 2'd1 : 2'd3);

	// Pack helper for host-side tests (same bit layout as PLXD upper word)
	// free[1:0] | disp<<2 | swap<<3 | frames<<16  — exposed via dbg
	(* keep = 1 *) wire [31:0] plxd_hi_keep = {
		frames_done,
		12'd0,
		swap_pending,
		disp_bank,
		free_mask
	};

	always @(posedge clk) begin
		if (reset) begin
			// Both banks free, displaying 0 conceptually but free_mask allows 1
			// first (product: free = ~disp when !swap_pending → free bank1 if disp0)
			disp_bank     <= 1'b0;
			pending_bank  <= 1'b0;
			swap_pending  <= 1'b0;
			free_mask     <= 2'b10; // bank1 free (disp holds 0) — product rule
			frames_done   <= 16'd0;
			claim_ack     <= 1'b0;
			claim_bank    <= 2'd0;
		end else begin
			claim_ack <= 1'b0;

			// Claim: exclusive take of one free bank
			if (claim_req && any_free && !claim_ack) begin
				claim_bank <= next_free_bank;
				claim_ack  <= 1'b1;
				if (next_free_bank == 2'd0)
					free_mask[0] <= 1'b0;
				else if (next_free_bank == 2'd1)
					free_mask[1] <= 1'b0;
			end

			// Commit: producer finished write+doorbell → pending display
			if (commit_pulse) begin
				pending_bank <= commit_bank[0];
				swap_pending <= 1'b1;
				free_mask    <= 2'b00; // both in use until vsync
			end

			// Vsync swap: pending → disp; old disp free (full-mask write)
			if (vsync_swap && swap_pending) begin
				free_mask    <= (2'b01 << disp_bank); // only old disp becomes free
				disp_bank    <= pending_bank;
				swap_pending <= 1'b0;
				frames_done  <= frames_done + 16'd1;
			end
		end
	end
endmodule

`default_nettype wire
