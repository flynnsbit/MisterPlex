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

	// Next-counter epoch (combinational). Blank/sync NBA must use these so the
	// registered HBlank/VBlank/HSync correspond to the same hc/vc visible after
	// the edge. Using pre-update hc made wrap observe hc=0 with HBlank still 1,
	// so in_content=(hc<H_DE)&&~hb dropped x=0 every line
	// (store_id_checked=959*V_ACTIVE=517860 vs 518400) — rd-duck 34ddf031.
	reg [10:0] hc_next;
	reg [10:0] vc_next;
	always @(*) begin
		if (hc == 11'(H_LAST)) begin
			hc_next = 11'd0;
			if (vc == 11'(V_LAST))
				vc_next = 11'd0;
			else
				vc_next = vc + 11'd1;
		end else begin
			hc_next = hc + 11'd1;
			vc_next = vc;
		end
	end

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
			hc <= hc_next;
			vc <= vc_next;
			if (hc == 11'(H_LAST) && vc == 11'(V_LAST))
				frame_start <= 1'b1;

			// Levels from *next* counters — same epoch as registered hc/vc.
			HBlank <= (hc_next >= 11'(H_DE));
			VBlank <= (vc_next >= 11'(V_ACTIVE));

			if (hc_next == 11'(H_SYNC_S))
				HSync <= 1'b1;
			if (hc_next == 11'(H_SYNC_E))
				HSync <= 1'b0;

			// VS edges on H_SYNC_S (Template-style keying), same epoch as hc_next.
			if (hc_next == 11'(H_SYNC_S)) begin
				if (vc_next == 11'(V_SYNC_S))
					VSync <= 1'b1;
				else if (vc_next == 11'(V_SYNC_E))
					VSync <= 1'b0;
			end
		end
	end
endmodule

`default_nettype wire
