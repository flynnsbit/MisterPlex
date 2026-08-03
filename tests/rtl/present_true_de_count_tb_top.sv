// Thin present_core DE path for counted true-DE sim.
// Mirrors PRESENT_BEAM_960 branch: beam → in_content → content_window → DE_LAG.
//
// Modes (C++ / +define):
//   product 30/24: DE=960×540 @ 1182×{564,705}
//   island / FAULT_VTOT_BAD_DE: existing reds
//   FAULT_STORE_ORACLE_PERM: identity-breaking store_x permute (B6 red twin)
//   FAULT_STORE_ORACLE_DROP: drop x=0 requests (B6 red twin alt)

`default_nettype none

module present_true_de_count_tb (
	input  wire        clk,
	input  wire        reset,
	input  wire        win_enable,
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,
	input  wire [10:0] content_x0,
	input  wire [10:0] content_y0,
	input  wire [10:0] win_h_de,
	input  wire [10:0] win_v_de,
	input  wire        use_rt_vtotal,
	input  wire [10:0] rt_vtotal,
	// Runtime DE geometry (0 = use param defaults). Latched in beam at frame wrap.
	input  wire        use_rt_geom,
	input  wire [10:0] rt_h_de,
	input  wire [10:0] rt_v_active,
	output wire        ce_pix,
	output wire        HBlank,
	output wire        VBlank,
	output wire        HSync,
	output wire        VSync,
	output wire        frame_start,
	output wire [10:0] hc,
	output wire [10:0] vc,
	output wire [10:0] vtot_active,
	output wire [10:0] hde_active,
	output wire [10:0] vact_active,
	output wire [10:0] store_x,
	output wire [10:0] store_y,
	output wire        de_out,
	output wire        in_content_raw
);
`ifdef PRESENT_BEAM_FAULT_ISLAND_1280
	localparam int P_H_DE = 1280;
	localparam int P_V_ACT = 720;
	localparam int P_H_TOT = 1650;
	localparam int P_V_TOT = 750;
`elsif PRESENT_BEAM_FAULT_VTOT_BAD_DE
	localparam int P_H_DE = 1280;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1400;
	localparam int P_V_TOT = 564;
`elsif PRESENT_BEAM_24_V705
	localparam int P_H_DE = 960;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1182;
	localparam int P_V_TOT = 564;
`else
	// Default product 960 class; multi-geom tests drive rt_h_de/rt_v_active.
	localparam int P_H_DE = 960;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1182;
	localparam int P_V_TOT = 564;
`endif

	wire ce_pix_i, hb, hs, vb, vs, fstart;
	wire [10:0] hc_i, vc_i;
	wire [10:0] vtot_act_i, hde_act_i, vact_act_i;

	present_beam_content_de #(
		.H_DE(P_H_DE),
		.V_ACTIVE(P_V_ACT),
		.H_TOTAL(P_H_TOT),
		.V_TOTAL(P_V_TOT),
		.H_SYNC_S(P_H_DE + 32),
		.H_SYNC_E(P_H_DE + 32 + 64),
		.V_SYNC_S(P_V_ACT + 8),
		.V_SYNC_E(P_V_ACT + 8 + 6)
	) beam (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(use_rt_vtotal),
		.rt_vtotal(rt_vtotal),
		.use_rt_geom(use_rt_geom),
		.rt_h_de(rt_h_de),
		.rt_v_active(rt_v_active),
		.ce_pix(ce_pix_i),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart),
		.hc_out(hc_i),
		.vc_out(vc_i),
		.vtot_active(vtot_act_i),
		.hde_active(hde_act_i),
		.vact_active(vact_act_i)
	);

	wire [10:0] py = vc_i;
	// in_content must track *active* DE (runtime), not only elab params.
	wire in_content = (hc_i < hde_act_i) && (py < vact_act_i) && ~hb && ~vb;

	wire [10:0] store_x_w, store_y_w;
	wire de_r, past_last_row;

	present_content_window #(
		.FRAME_W(960),
		.FRAME_H(540),
		.STORE_W(1280),
		.STORE_H(720),
		.H_DE_DEFAULT(P_H_DE),
		.V_DE_DEFAULT(P_V_ACT)
	) content_win (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix_i),
		.hc(hc_i),
		.py(py),
		.in_content(in_content),
		.win_enable(win_enable),
		.content_w(content_w),
		.content_h(content_h),
		.content_x0(content_x0),
		.content_y0(content_y0),
		.h_de(win_h_de),
		.v_de(win_v_de),
		.store_x(store_x_w),
		.store_y(store_y_w),
		.de_r(de_r),
		.past_last_row(past_last_row)
	);

	// B6 red twins: break store coordinate oracle while keeping DE counts plausible.
`ifdef PRESENT_BEAM_FAULT_STORE_ORACLE_PERM
	// Bijection on x (swap even/odd) — count+range can look fine; identity/visit oracle must RED.
	wire [10:0] store_x_o = store_x_w ^ 11'd1;
	wire [10:0] store_y_o = store_y_w;
`elsif PRESENT_BEAM_FAULT_STORE_ORACLE_DROP
	// Drop x==0: replace with x==1 → missing 0, duplicate 1.
	wire [10:0] store_x_o = (store_x_w == 11'd0) ? 11'd1 : store_x_w;
	wire [10:0] store_y_o = store_y_w;
`else
	wire [10:0] store_x_o = store_x_w;
	wire [10:0] store_y_o = store_y_w;
`endif

	localparam int DE_LAG = 3;
	reg [DE_LAG-1:0] hb_sr, hs_sr;
	always @(posedge clk) begin
		if (reset) begin
			hb_sr <= {DE_LAG{1'b1}};
			hs_sr <= {DE_LAG{1'b0}};
		end else begin
			hb_sr <= {hb_sr[DE_LAG-2:0], hb};
			hs_sr <= {hs_sr[DE_LAG-2:0], hs};
		end
	end
	wire hb_d = hb_sr[DE_LAG-1];
	wire hs_d = hs_sr[DE_LAG-1];
	wire vb_d = vb | past_last_row;

	assign ce_pix = ce_pix_i;
	assign HBlank = hb_d;
	assign HSync = hs_d;
	assign VBlank = vb_d;
	assign VSync = vs;
	assign frame_start = fstart;
	assign hc = hc_i;
	assign vc = vc_i;
	assign vtot_active = vtot_act_i;
	assign hde_active = hde_act_i;
	assign vact_active = vact_act_i;
	assign store_x = store_x_o;
	assign store_y = store_y_o;
	assign de_out = ~hb_d & ~vb_d;
	assign in_content_raw = in_content;
endmodule

`default_nettype wire
