// host_bank_ingest_credit — handshake card for HPS zero-copy / PL330 ingest (w-path)
// ↔ fabric bank consumer (w-mem frame_store / fabric_ddr_writer reader side).
//
// Default: NOT instantiated in product (no Plex.qsf change). Lint/elab only until
// integration fit. Mirrors the software contract in ddr_zero_copy_ingest.hpp:
//
//   1) FPGA grants bank credit (free bank)  → host may fill that bank
//   2) Host moves payload (CPU or PL330)    → must finish before doorbell
//   3) Host rings doorbell (PLXK)           → FPGA may display
//   4) FPGA releases bank after scanout     → credit returns
//
// This module does NOT move pixels. It only tracks credit vs pending doorbell
// so a careless host cannot be "helped" into tearing by fabric logic.
//
// Clock: clk_sys (same as present status domain). CDC to HPS is via existing
// doorbell/PLXD mailboxes — this block is the fabric-side scoreboard.
//
`default_nettype none

module host_bank_ingest_credit #(
	parameter int NUM_BANKS = 2
)(
	input  wire        clk,
	input  wire        reset,

	// From frame_store / PLXD path: bank is free for host fill
	input  wire [NUM_BANKS-1:0] bank_free_mask,

	// From doorbell decode: host published this bank (one-cycle pulse)
	input  wire        doorbell_pulse,
	input  wire        doorbell_bank, // 1-bit product field

	// From present: bank retired after display (one-cycle pulse)
	input  wire        retire_pulse,
	input  wire        retire_bank,

	// Scoreboard
	output reg  [NUM_BANKS-1:0] host_may_fill_mask,
	output reg                  err_doorbell_without_credit,
	output reg                  err_double_publish
);

	reg [NUM_BANKS-1:0] in_flight; // published, not yet retired

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			in_flight                   <= {NUM_BANKS{1'b0}};
			host_may_fill_mask          <= {NUM_BANKS{1'b1}};
			err_doorbell_without_credit <= 1'b0;
			err_double_publish          <= 1'b0;
		end else begin
			// Defaults: may fill when free and not in-flight
			for (i = 0; i < NUM_BANKS; i = i + 1)
				host_may_fill_mask[i] <= bank_free_mask[i] & ~in_flight[i];

			if (doorbell_pulse) begin
				if (!host_may_fill_mask[doorbell_bank])
					err_doorbell_without_credit <= 1'b1;
				if (in_flight[doorbell_bank])
					err_double_publish <= 1'b1;
				in_flight[doorbell_bank] <= 1'b1;
			end

			if (retire_pulse)
				in_flight[retire_bank] <= 1'b0;
		end
	end

endmodule

`default_nettype wire
