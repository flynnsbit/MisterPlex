// plxd_bank_credit — PLXD free/disp/swap scoreboard for external producers
// (ARM memcpy today, PL330/fabric DMA tomorrow).
//
// Does NOT move pixels. Enforces the same ownership ABI as ddr_frame_store PLXD:
//   free_mask = swap_pending ? 2'b00 : (disp_bank ? 2'b01 : 2'b10)
//   claim free bank → fill (CPU or DMA) → doorbell → vsync retire
//
// Sticky errors (never silent tear help):
//   err_doorbell_without_credit — ring while free bit clear / already pending
//   err_double_claim            — claim bank already filling or display
//
// Not in files.qip until parent wires it (lint/Verilator only). Product PLXD
// pack in ddr_frame_store remains authoritative; this module is the portable
// contract card for DMA lanes.
//
`default_nettype none

module plxd_bank_credit (
	input  wire       clk,
	input  wire       reset,

	// Mirror of frame_store bank FSM (or self-contained when STANDALONE=1)
	input  wire       vsync_pulse,
	input  wire       pending_ready,   // prep complete; swap may commit

	// Producer API
	input  wire       claim_req,       // one-cycle: take free bank
	output reg        claim_ack,
	output reg        claim_bank,      // 0 or 1 when ack

	input  wire       doorbell_pulse,  // one-cycle: bank filled + published
	input  wire       doorbell_bank,

	// PLXD-compatible outputs (FPGA→host mailbox fields)
	output reg  [1:0] free_bank_mask,
	output reg        disp_bank,
	output reg        swap_pending,
	output reg        pending_bank,
	output reg [15:0] frames_done,
	output reg        has_frame,

	// Mid-fill: claimed, not yet doorbell'd
	output reg  [1:0] filling_mask,

	output reg        err_doorbell_without_credit,
	output reg        err_double_claim
);
	// free when !swap_pending: opposite of disp (ABI mailbox_abi_spec.hpp)
	wire [1:0] free_idle = disp_bank ? 2'b01 : 2'b10;

	always @(posedge clk) begin
		if (reset) begin
			disp_bank     <= 1'b0;
			pending_bank  <= 1'b0;
			swap_pending  <= 1'b0;
			free_bank_mask <= 2'b10; // bank1 free, disp=0
			frames_done   <= 16'd0;
			has_frame     <= 1'b0;
			filling_mask  <= 2'b00;
			claim_ack     <= 1'b0;
			claim_bank    <= 1'b0;
			err_doorbell_without_credit <= 1'b0;
			err_double_claim            <= 1'b0;
		end else begin
			claim_ack <= 1'b0;

			// Refresh free mask every cycle from ownership state.
			// While swap_pending: both banks in use → free=00.
			// Else: free = ~disp, minus any filling bits still held.
			if (swap_pending)
				free_bank_mask <= 2'b00;
			else
				free_bank_mask <= free_idle & ~filling_mask;

			// Claim exclusive free bank
			if (claim_req) begin
				if (free_bank_mask[0]) begin
					claim_ack    <= 1'b1;
					claim_bank   <= 1'b0;
					filling_mask[0] <= 1'b1;
				end else if (free_bank_mask[1]) begin
					claim_ack    <= 1'b1;
					claim_bank   <= 1'b1;
					filling_mask[1] <= 1'b1;
				end else begin
					err_double_claim <= 1'b1;
				end
			end

			// Doorbell: must be filling that bank; arms swap_pending
			if (doorbell_pulse) begin
				if (!filling_mask[doorbell_bank] || swap_pending) begin
					err_doorbell_without_credit <= 1'b1;
				end else begin
					pending_bank <= doorbell_bank;
					swap_pending <= 1'b1;
					filling_mask[doorbell_bank] <= 1'b0;
				end
			end

			// Vsync commit when prep ready (same gate as ddr_frame_store)
			if (vsync_pulse && swap_pending && pending_ready) begin
				disp_bank    <= pending_bank;
				has_frame    <= 1'b1;
				swap_pending <= 1'b0;
				frames_done  <= frames_done + 16'd1;
			end
		end
	end

endmodule

`default_nettype wire
