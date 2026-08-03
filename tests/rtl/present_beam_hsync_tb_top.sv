// Dual-geometry wrapper for present_beam_content_de HSync/VSync gate.
// sel=1 → L4 1280×720 H=1312 V=762 (present_core L4 params)
// sel=0 → 320×240-class H=400 V=262 with FP=8 SW=8 (tight blanking)
`default_nettype none

module present_beam_hsync_tb_top (
	input  wire        clk,
	input  wire        reset,
	input  wire        sel,
	output wire        HSync,
	output wire        VSync,
	output wire        HBlank,
	output wire        VBlank,
	output wire        frame_start,
	output wire [10:0] hc_out,
	output wire [10:0] vc_out
);
	wire hs0, vs0, hb0, vb0, fs0;
	wire hs1, vs1, hb1, vb1, fs1;
	wire [10:0] hc0, vc0, hc1, vc1;
	wire [10:0] unused_a0, unused_b0, unused_c0, unused_d0;
	wire [10:0] unused_a1, unused_b1, unused_c1, unused_d1;
	wire ce0, ce1;

	// 320×240-class — content size; H_SYNC sets FP=8/SW=8; H_FP defaults
	// left at 32/64 (would not fit blanking=80: 320+32+64=416>400).
	present_beam_content_de #(
		.H_DE(320),
		.V_ACTIVE(240),
		.H_TOTAL(400),
		.V_TOTAL(262),
		.H_SYNC_S(320 + 8),
		.H_SYNC_E(320 + 8 + 8),
		.V_SYNC_S(240 + 3),
		.V_SYNC_E(240 + 3 + 3)
		// H_FP/H_SW defaults 32/64 — must NOT be used when H_SYNC_* valid
	) u_beam_320 (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b0),
		.rt_vtotal(11'd0),
		.use_rt_geom(1'b1),
		.rt_h_de(11'd320),
		.rt_h_total(11'd400),
		.rt_v_active(11'd240),
		.ce_pix(ce0),
		.HBlank(hb0),
		.HSync(hs0),
		.VBlank(vb0),
		.VSync(vs0),
		.frame_start(fs0),
		.hc_out(hc0),
		.vc_out(vc0),
		.vtot_active(unused_a0),
		.hde_active(unused_b0),
		.htot_active(unused_c0),
		.vact_active(unused_d0)
	);

	// L4 — same wiring footgun as pre-fix present_core: H_SYNC_S/E set for
	// FP=8/SW=8, but H_FP/H_SW left at module defaults (32/64). Without the
	// H_SYNC-relative rt porch fix, hs_s=1312 → HSync never asserts.
	// H_FP/H_SW intentionally NOT overridden here (negative twin of "only
	// pass absolute H_SYNC_* and hope").
	present_beam_content_de #(
		.H_DE(1280),
		.V_ACTIVE(720),
		.H_TOTAL(1312),
		.V_TOTAL(762),
		.H_SYNC_S(1280 + 8),
		.H_SYNC_E(1280 + 8 + 8),
		.V_SYNC_S(720 + 8),
		.V_SYNC_E(720 + 8 + 6)
		// H_FP=32 H_SW=64 V_FP=8 V_SW=6 defaults
	) u_beam_l4 (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b0),
		.rt_vtotal(11'd0),
		.use_rt_geom(1'b1),
		.rt_h_de(11'd1280),
		.rt_h_total(11'd1312),
		.rt_v_active(11'd720),
		.ce_pix(ce1),
		.HBlank(hb1),
		.HSync(hs1),
		.VBlank(vb1),
		.VSync(vs1),
		.frame_start(fs1),
		.hc_out(hc1),
		.vc_out(vc1),
		.vtot_active(unused_a1),
		.hde_active(unused_b1),
		.htot_active(unused_c1),
		.vact_active(unused_d1)
	);

	assign HSync = sel ? hs1 : hs0;
	assign VSync = sel ? vs1 : vs0;
	assign HBlank = sel ? hb1 : hb0;
	assign VBlank = sel ? vb1 : vb0;
	assign frame_start = sel ? fs1 : fs0;
	assign hc_out = sel ? hc1 : hc0;
	assign vc_out = sel ? vc1 : vc0;

	wire _unused = ce0 | ce1;
endmodule

`default_nettype wire
