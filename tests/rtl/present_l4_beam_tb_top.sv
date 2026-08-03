// present_l4_beam_tb_top — exercise L4 720p24 beam geometry in isolation.
// Product QSF stays default-off; this top forces L4 constants as parameters.
//
// Expected (w-clock / dual-header):
//   H_DE=1280 V_ACTIVE=720 H_TOTAL=1312 V_TOTAL=762
// No PLL required: counts are in ce_pix cycles at whatever clk the TB supplies.

`default_nettype none

module present_l4_beam_tb_top #(
	parameter int H_DE     = 1280,
	parameter int V_ACTIVE = 720,
	parameter int H_TOTAL  = 1312,
	parameter int V_TOTAL  = 762,
	// Blanking is only H_TOTAL-H_DE (=32). H_FP+H_SW must fit inside it.
	parameter int H_FP     = 8,
	parameter int H_SW     = 8,
	parameter int V_FP     = 8,
	parameter int V_SW     = 6
)(
	input  wire        clk,
	input  wire        reset,
	output wire        ce_pix,
	output wire        HBlank,
	output wire        HSync,
	output wire        VBlank,
	output wire        VSync,
	output wire        frame_start,
	output wire [10:0] hc,
	output wire [10:0] vc,
	output wire [10:0] hde_active,
	output wire [10:0] htot_active,
	output wire [10:0] vact_active,
	output wire [10:0] vtot_active
);
	present_beam_content_de #(
		.H_DE(H_DE),
		.V_ACTIVE(V_ACTIVE),
		.H_TOTAL(H_TOTAL),
		.V_TOTAL(V_TOTAL),
		.H_SYNC_S(H_DE + H_FP),
		.H_SYNC_E(H_DE + H_FP + H_SW),
		.V_SYNC_S(V_ACTIVE + V_FP),
		.V_SYNC_E(V_ACTIVE + V_FP + V_SW),
		.H_FP(H_FP),
		.H_SW(H_SW),
		.V_FP(V_FP),
		.V_SW(V_SW)
	) dut (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b0),
		.rt_vtotal(11'd0),
		// use_rt_geom=0: fixed params (matches L4 after H_FP fix path)
		.use_rt_geom(1'b0),
		.rt_h_de(11'd0),
		.rt_h_total(11'd0),
		.rt_v_active(11'd0),
		.ce_pix(ce_pix),
		.HBlank(HBlank),
		.HSync(HSync),
		.VBlank(VBlank),
		.VSync(VSync),
		.frame_start(frame_start),
		.hc_out(hc),
		.vc_out(vc),
		.vtot_active(vtot_active),
		.hde_active(hde_active),
		.htot_active(htot_active),
		.vact_active(vact_active)
	);
endmodule

`default_nettype wire
