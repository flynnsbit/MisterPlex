// Thin present_core DE path for counted true-DE sim.
// Mirrors PRESENT_BEAM_960 branch: beam → in_content → content_window → DE_LAG.
//
// Modes (C++ / +define):
//   product 30: H=1182 V=564  DE=960×540
//   product 24: H=1182 V=705  DE=960×540  (parent fixed-H film class)
//   island:     beam 1280×720
//   FAULT_VTOT_BAD_DE: V_TOT=705 but DE width left at 1280

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
	output wire        ce_pix,
	output wire        HBlank,
	output wire        VBlank,
	output wire        HSync,
	output wire        VSync,
	output wire        frame_start,
	output wire [10:0] hc,
	output wire [10:0] vc,
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
	// Film-rate blanking intent (V via rt=705) but DE left at canvas width.
	// H_TOTAL must exceed H_DE; keep generous line like 1400×705 class.
	localparam int P_H_DE = 1280;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1400;
	localparam int P_V_TOT = 564;
`elsif PRESENT_BEAM_24_V705
	// Same param defaults as 30; film rate via runtime rt_vtotal=705 (parent design).
	localparam int P_H_DE = 960;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1182;
	localparam int P_V_TOT = 564;
`else
	localparam int P_H_DE = 960;
	localparam int P_V_ACT = 540;
	localparam int P_H_TOT = 1182;
	localparam int P_V_TOT = 564;
`endif

	wire ce_pix_i, hb, hs, vb, vs, fstart;
	wire [10:0] hc_i, vc_i;

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
		.ce_pix(ce_pix_i),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart),
		.hc_out(hc_i),
		.vc_out(vc_i)
	);

	wire [10:0] py = vc_i;
	wire in_content = (hc_i < 11'(P_H_DE)) && (py < 11'(P_V_ACT)) && ~hb && ~vb;

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
	assign store_x = store_x_w;
	assign store_y = store_y_w;
	assign de_out = ~hb_d & ~vb_d;
	assign in_content_raw = in_content;
endmodule

`default_nettype wire
