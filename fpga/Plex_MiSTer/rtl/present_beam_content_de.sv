// present_beam_content_de — progressive content-sized DE beam (ascal-native).
//
// Emits true content DE: HBlank low for H_DE cycles, VBlank low for V_ACTIVE lines.
// Default numbers match w-clock present_video_timing_960 MODE=0 (1182×564 @ 20 MHz → ~30.0008 Hz).
// Film companion (parent): same H_TOTAL=1182, V_TOTAL=705 → ~24.0007 Hz (20e6/24/1182≈705.02).
//
// Runtime V_TOTAL (use_rt_vtotal=1): host may write rt_vtotal anytime (CDC-safe).
// Request is *captured* every cycle; *applied* only on frame wrap (v_wrap) or reset.
// Combinational use of rt_vtotal as v_last is FORBIDDEN — a mid-frame 705→564 with
// vc>563 never hits vc==v_last and stalls frame_start (rd-duck).
//
// Same-epoch blanking: blanks/sync from *next* hc/vc so levels match hc_out/vc_out.

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
	// Runtime V_TOTAL request (applied at frame boundary only).
	input  wire        use_rt_vtotal,
	input  wire [10:0] rt_vtotal,
	output reg         ce_pix,
	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         frame_start,
	output wire [10:0] hc_out,
	output wire [10:0] vc_out,
	// Active V_TOTAL for the frame currently in progress (post-latch).
	output wire [10:0] vtot_active
);
	wire [10:0] vtot_min = 11'(V_ACTIVE + 16);
	wire [10:0] vtot_req_raw = use_rt_vtotal ? rt_vtotal : 11'(V_TOTAL);
	wire [10:0] vtot_req = (vtot_req_raw < vtot_min) ? vtot_min : vtot_req_raw;

	// Elab pins — parameter defaults.
	// synthesis translate_off
	initial begin
		if (H_TOTAL <= H_DE) $error("present_beam_content_de: H_TOTAL must exceed H_DE");
		if (V_TOTAL <= V_ACTIVE) $error("present_beam_content_de: V_TOTAL must exceed V_ACTIVE");
		if (H_SYNC_E >= H_TOTAL) $error("present_beam_content_de: H_SYNC past line");
		if (V_SYNC_E >= V_TOTAL) $error("present_beam_content_de: V_SYNC past default frame");
	end
	// synthesis translate_on

	reg [10:0] hc;
	reg [10:0] vc;
	reg [10:0] vtot_act; // latched — drives v_last for this frame only
	assign hc_out = hc;
	assign vc_out = vc;
	assign vtot_active = vtot_act;

	wire [10:0] h_last = 11'(H_TOTAL - 1);
	wire [10:0] v_last = vtot_act - 11'd1;

	// Next-cycle counters — blanks/sync register from these so levels match hc/vc after NBA.
	wire        h_wrap = (hc == h_last);
	wire        v_wrap = h_wrap && (vc == v_last);
	wire [10:0] hc_n   = h_wrap ? 11'd0 : (hc + 11'd1);
	wire [10:0] vc_n   = h_wrap ? (v_wrap ? 11'd0 : (vc + 11'd1)) : vc;

	always @(posedge clk) begin
		ce_pix <= 1'b1;
		frame_start <= 1'b0;

		if (reset) begin
			hc <= 11'd0;
			vc <= 11'd0;
			// Sample request at reset so first frame matches host without waiting a wrap.
			vtot_act <= vtot_req;
			ce_pix <= 1'b0;
			HBlank <= 1'b0;
			HSync  <= 1'b0;
			VBlank <= (11'(0) >= 11'(V_ACTIVE));
			VSync  <= 1'b0;
		end else begin
			// Apply pending request only when completing a frame → next frame uses new V.
			if (v_wrap)
				vtot_act <= vtot_req;

			hc <= hc_n;
			vc <= vc_n;
			if (v_wrap)
				frame_start <= 1'b1;

			HBlank <= (hc_n >= 11'(H_DE));
			VBlank <= (vc_n >= 11'(V_ACTIVE));
			HSync  <= (hc_n >= 11'(H_SYNC_S)) && (hc_n < 11'(H_SYNC_E));
			VSync  <= (vc_n >= 11'(V_SYNC_S)) && (vc_n < 11'(V_SYNC_E));
		end
	end
endmodule

`default_nettype wire
