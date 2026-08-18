// present_15k_store_map — combinational 15 kHz beam → 640×480 I420 store
//
// Bob (mode_weave=0, DROP): store_x=(hc<<1)|X_PARITY, store_y=(vc<<1)|Y_PARITY
// Weave (mode_weave=1):     store_x=hc; y={vc,field_odd}  (even 2*vc, odd 2*vc+1)
// Clamp to 639/479. No clocks. Pillars 11+11 stay in ddr_frame_store.
// Not in files.qip until instantiated (orphan QIP is a L10/L11 hazard).

`timescale 1ns / 1ps
`default_nettype none

module present_15k_store_map (
	input  wire [10:0] hc,
	input  wire [10:0] vc,
	input  wire        field_odd,
	input  wire        mode_weave,
	output wire [10:0] store_x,
	output wire [10:0] store_y
);
	`include "plex_15k_bw_contract.svh"

	localparam [11:0] LAST_X = 12'(P15K_STORE_W - 1);
	localparam [11:0] LAST_Y = 12'(P15K_STORE_H - 1);

	// synthesis translate_off
	initial begin
		if (P15K_STORE_W != 640 || P15K_STORE_H != 480)
			$error("present_15k_store_map: store must stay 640x480");
		if (P15K_PHYS_BASE != 32'h3000_0000)
			$error("present_15k_store_map: PHYS_BASE must be 0x30000000");
		if (P15K_DOORBELL_PHYS != 32'h300F_F000)
			$error("present_15k_store_map: doorbell must be 0x300FF000");
		if (P15K_NEW_DOORBELL)
			$error("present_15k_store_map: no new 320x240 doorbell");
	end
	// synthesis translate_on

	wire [11:0] x_raw = mode_weave ? {1'b0, hc} : {hc, P15K_BOB_X_PARITY};
	wire [11:0] y_raw = mode_weave ? {vc, field_odd} : {vc, P15K_BOB_Y_PARITY};

	assign store_x = (x_raw > LAST_X) ? LAST_X[10:0] : x_raw[10:0];
	assign store_y = (y_raw > LAST_Y) ? LAST_Y[10:0] : y_raw[10:0];
endmodule

`default_nettype wire
