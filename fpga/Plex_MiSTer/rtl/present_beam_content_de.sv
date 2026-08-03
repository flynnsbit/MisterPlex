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
// Runtime DE geometry (use_rt_geom=1): rt_h_de / rt_v_active applied on the same
// frame boundary as V_TOTAL. PMS delivers source-native sizes (320×240, 640×360,
// 960×540 max) — true DE must track content, not a hard-coded 960×540 island.
// H_TOTAL stays fixed (blanking absorbs smaller DE). h_de must be < H_TOTAL.
//
// Same-epoch blanking: blanks/sync from *next* hc/vc so levels match hc_out/vc_out.
// Fmax: DE compares are 11-bit against registers (same structure as param path);
// no pixel-path multiply/divide here. Margin at 20 MHz is timing-class not logic-depth.

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
	// Runtime DE size (applied at frame boundary only). 0 → keep param default.
	input  wire        use_rt_geom,
	input  wire [10:0] rt_h_de,
	input  wire [10:0] rt_v_active,
	output reg         ce_pix,
	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         frame_start,
	output wire [10:0] hc_out,
	output wire [10:0] vc_out,
	// Active totals/geometry for the frame currently in progress (post-latch).
	output wire [10:0] vtot_active,
	output wire [10:0] hde_active,
	output wire [10:0] vact_active
);
	// --- request clamp ---
	// V_TOTAL must leave room for V_ACTIVE + minimal blank.
	wire [10:0] hde_req_raw = use_rt_geom ? rt_h_de : 11'(H_DE);
	wire [10:0] vact_req_raw = use_rt_geom ? rt_v_active : 11'(V_ACTIVE);
	// Reject 0 and require H_DE < H_TOTAL, V_ACTIVE + 16 <= V_TOTAL class.
	wire [10:0] hde_req =
		(hde_req_raw == 11'd0) ? 11'(H_DE) :
		(hde_req_raw >= 11'(H_TOTAL)) ? 11'(H_TOTAL - 1) : hde_req_raw;
	wire [10:0] vact_req =
		(vact_req_raw == 11'd0) ? 11'(V_ACTIVE) : vact_req_raw;

	// vtot_min tracks *requested* active so a 240-line DE can still use V_TOTAL=564.
	wire [10:0] vtot_min = vact_req + 11'd16;
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
	reg [10:0] hde_act;
	reg [10:0] vact_act;
	assign hc_out = hc;
	assign vc_out = vc;
	assign vtot_active = vtot_act;
	assign hde_active = hde_act;
	assign vact_active = vact_act;

	wire [10:0] h_last = 11'(H_TOTAL - 1);
	wire [10:0] v_last = vtot_act - 11'd1;

	// Next-cycle counters — blanks/sync register from these so levels match hc/vc after NBA.
	wire        h_wrap = (hc == h_last);
	wire        v_wrap = h_wrap && (vc == v_last);
	wire [10:0] hc_n   = h_wrap ? 11'd0 : (hc + 11'd1);
	wire [10:0] vc_n   = h_wrap ? (v_wrap ? 11'd0 : (vc + 11'd1)) : vc;

	// Sync placement: keep param defaults when DE shrinks (still inside blank).
	// If runtime DE grows past param sync start, push sync into remaining blank.
	wire [10:0] hs_s_eff = (hde_act + 11'd32 < 11'(H_TOTAL)) ? (hde_act + 11'd32) : 11'(H_SYNC_S);
	wire [10:0] hs_e_eff = (hs_s_eff + 11'd64 < 11'(H_TOTAL)) ? (hs_s_eff + 11'd64) : 11'(H_TOTAL - 1);
	wire [10:0] vs_s_eff = (vact_act + 11'd8 < vtot_act) ? (vact_act + 11'd8) : (vtot_act - 11'd8);
	wire [10:0] vs_e_eff = (vs_s_eff + 11'd6 < vtot_act) ? (vs_s_eff + 11'd6) : vtot_act;

	always @(posedge clk) begin
		ce_pix <= 1'b1;
		frame_start <= 1'b0;

		if (reset) begin
			hc <= 11'd0;
			vc <= 11'd0;
			// Sample request at reset so first frame matches host without waiting a wrap.
			hde_act  <= hde_req;
			vact_act <= vact_req;
			vtot_act <= vtot_req;
			ce_pix <= 1'b0;
			HBlank <= 1'b0;
			HSync  <= 1'b0;
			VBlank <= 1'b0;
			VSync  <= 1'b0;
		end else begin
			// Apply pending request only when completing a frame → next frame uses new geom.
			if (v_wrap) begin
				hde_act  <= hde_req;
				vact_act <= vact_req;
				vtot_act <= vtot_req;
			end

			hc <= hc_n;
			vc <= vc_n;
			if (v_wrap)
				frame_start <= 1'b1;

			HBlank <= (hc_n >= hde_act);
			VBlank <= (vc_n >= vact_act);
			HSync  <= (hc_n >= hs_s_eff) && (hc_n < hs_e_eff);
			VSync  <= (vc_n >= vs_s_eff) && (vc_n < vs_e_eff);
		end
	end
endmodule

`default_nettype wire
