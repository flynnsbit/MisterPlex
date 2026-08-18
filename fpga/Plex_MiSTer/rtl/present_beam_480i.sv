// 15 kHz 480i weave raster (sibling QSF Plex_480i; not product Plex.qsf).
// clk_sys stays 20 MHz (L52). CE 2/3 -> 40e6/3 Hz pix.
// 849 x 262 per field, 640 x 240 active, FRAME_LINES=524, HALFLINE=0:
//   H     = 40e6 / (3*849)         = 15704.750687 Hz
//   field = 20e6 / 333657          = 59.94179652 Hz
// Store stays 640x480 TRUE_480P; present_core weaves y={vc, field_odd}.
// Numbers from plex_15k_bw_contract.svh (w-clock lock). No new PLL.

`default_nettype none

module present_beam_480i (
	input  wire        clk,
	input  wire        reset,
	output reg         ce_pix,
	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         frame_start,
	output reg  [10:0] hc_out,
	output reg  [10:0] vc_out,
	output reg         field_odd
);
	// Shared 15 kHz contract (bob + weave + store). Weave uses P15K_I_*.
	/* verilator lint_off UNUSEDPARAM */
	`include "plex_15k_bw_contract.svh"
	/* verilator lint_on UNUSEDPARAM */

	localparam [10:0] H_DE     = 11'(P15K_I_H_DE);
	localparam [10:0] V_ACTIVE = 11'(P15K_I_V_ACTIVE);
	localparam [10:0] H_TOTAL  = 11'(P15K_I_H_TOTAL);
	localparam [10:0] V_TOTAL  = 11'(P15K_I_V_TOTAL);
	localparam [10:0] H_SYNC_S = 11'(P15K_I_H_SYNC_S);
	localparam [10:0] H_SYNC_E = 11'(P15K_I_H_SYNC_E);
	localparam [10:0] V_SYNC_S = 11'(P15K_I_V_SYNC_S);
	localparam [10:0] V_SYNC_E = 11'(P15K_I_V_SYNC_E);

	// This cut is the integer no-half-line beam. A later 525-line cut
	// would need a mid-line VSync path that this module does not have.
	generate
		if (P15K_I_HALFLINE != 1'b0) begin : g_halfline_unsupported
			P15K_I_HALFLINE_NOT_SUPPORTED u_contract_error();
		end
		if (P15K_I_H_TOTAL != 849 || P15K_I_V_TOTAL != 262 ||
		    P15K_I_H_DE != 640 || P15K_I_V_ACTIVE != 240) begin : g_geom_mismatch
			P15K_I_GEOM_MUST_BE_849X262_640X240 u_contract_error();
		end
	endgenerate

	reg [1:0] ce_div;

	wire h_wrap = (hc_out == (H_TOTAL - 11'd1));
	wire v_wrap = h_wrap && (vc_out == (V_TOTAL - 11'd1));
	wire [10:0] hc_n = h_wrap ? 11'd0 : (hc_out + 11'd1);
	wire [10:0] vc_n = h_wrap ? (v_wrap ? 11'd0 : (vc_out + 11'd1)) : vc_out;

	always @(posedge clk) begin
		frame_start <= 1'b0;
		if (reset) begin
			hc_out <= 11'd0;
			vc_out <= 11'd0;
			ce_div <= 2'd0;
			ce_pix <= 1'b0;
			HBlank <= 1'b0;
			HSync <= 1'b0;
			VBlank <= 1'b0;
			VSync <= 1'b0;
			field_odd <= P15K_I_FIRST_ODD;
		end else begin
			// CE 2/3 registered, same if (ce_pix) style as present_beam_240p15.
			// Fire 2 of every 3 clk_sys (pattern 1,1,0): skip when ce_div==2.
			if (ce_div == 2'd2) begin
				ce_div <= 2'd0;
				ce_pix <= 1'b0;
			end else begin
				ce_div <= ce_div + 2'd1;
				ce_pix <= 1'b1;
			end
			if (ce_pix) begin
				hc_out <= hc_n;
				vc_out <= vc_n;
				HBlank <= (hc_n >= H_DE);
				HSync <= (hc_n >= H_SYNC_S) && (hc_n < H_SYNC_E);
				VBlank <= (vc_n >= V_ACTIVE);
				VSync <= (vc_n >= V_SYNC_S) && (vc_n < V_SYNC_E);
				if (v_wrap) begin
					field_odd <= ~field_odd;
					// First field is odd. Pulse once per frame after the even
					// field completes (odd+even = one 524-line frame).
					frame_start <= ~field_odd;
				end
			end
		end
	end
endmodule

`default_nettype wire
