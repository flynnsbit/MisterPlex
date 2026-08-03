// present_beam_content_de — progressive content-sized DE beam (ascal-native).
//
// Emits true content DE: HBlank low for H_DE cycles, VBlank low for V_ACTIVE lines.
// Default numbers match w-clock present_video_timing_960 MODE=0 (1182×564 @ 20 MHz → ~30.0008 Hz).
//
// Default OFF at present_core: `PRESENT_BEAM_960`. Does not replace Template colorbars
// unless that macro is set. Island FAULT twin: PRESENT_BEAM_FAULT_ISLAND_1280 forces
// H_DE=1280 / V_ACTIVE=720 while product content remains 960×540 (counter must RED).

`default_nettype none

module present_beam_content_de #(
	parameter int H_DE      = 960,
	parameter int V_ACTIVE  = 540,
	parameter int H_TOTAL   = 1182,
	parameter int V_TOTAL   = 564,
	parameter int H_SYNC_S  = 960 + 32,
	parameter int H_SYNC_E  = 960 + 32 + 64,
	parameter int V_SYNC_S  = 540 + 8,
	parameter int V_SYNC_E  = 540 + 8 + 6
)(
	input  wire        clk,
	input  wire        reset,
	output reg         ce_pix,
	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         frame_start,
	output wire [10:0] hc_out,
	output wire [10:0] vc_out
);
	localparam int H_LAST = H_TOTAL - 1;
	localparam int V_LAST = V_TOTAL - 1;

	// Elab pins — must match w-clock primary class for product MODE.
	// synthesis translate_off
	initial begin
		if (H_TOTAL <= H_DE) $error("present_beam_content_de: H_TOTAL must exceed H_DE");
		if (V_TOTAL <= V_ACTIVE) $error("present_beam_content_de: V_TOTAL must exceed V_ACTIVE");
		if (H_SYNC_E > H_LAST) $error("present_beam_content_de: H_SYNC past line");
		if (V_SYNC_E > V_LAST) $error("present_beam_content_de: V_SYNC past frame");
	end
	// synthesis translate_on

	reg [10:0] hc;
	reg [10:0] vc;
	assign hc_out = hc;
	assign vc_out = vc;

	always @(posedge clk) begin
		// 1 clk/pix path @ clk_sys (20 MHz) — matches w-clock B1 1px content DE plan.
		ce_pix <= 1'b1;
		frame_start <= 1'b0;

		if (reset) begin
			hc <= 11'd0;
			vc <= 11'd0;
			ce_pix <= 1'b0;
			HBlank <= 1'b1;
			HSync  <= 1'b0;
			VBlank <= 1'b1;
			VSync  <= 1'b0;
		end else begin
			// Advance on every cycle (ce_pix sticky 1 after reset release).
			if (hc == 11'(H_LAST)) begin
				hc <= 11'd0;
				if (vc == 11'(V_LAST)) begin
					vc <= 11'd0;
					frame_start <= 1'b1;
				end else begin
					vc <= vc + 11'd1;
				end
			end else begin
				hc <= hc + 11'd1;
			end

			// Level blanks from *current* counters (same-cycle as colorbars style).
			HBlank <= (hc >= 11'(H_DE));
			VBlank <= (vc >= 11'(V_ACTIVE));

			if (hc == 11'(H_SYNC_S))
				HSync <= 1'b1;
			if (hc == 11'(H_SYNC_E))
				HSync <= 1'b0;

			// VS edges on H_SYNC_S (Template-style keying).
			if (hc == 11'(H_SYNC_S)) begin
				if (vc == 11'(V_SYNC_S))
					VSync <= 1'b1;
				else if (vc == 11'(V_SYNC_E))
					VSync <= 1'b0;
			end
		end
	end
endmodule

`default_nettype wire
