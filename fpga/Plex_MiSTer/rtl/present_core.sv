// Present core: color bars OR external frame_store, cadence, tone + audio FIFO.
// Display owns VSync; unique content advances only when present_cadence says so.
//
// 720p / ascal-native present path (landed; DEFAULT OFF):
//   `define PLEX_PRESENT_720P_L4 — L4 product 720p24 path:
//       present_beam_content_de DE 1280×720, H_TOTAL=1312, V_TOTAL=762
//       (w-clock measured: 24e6/(1312*762)=24.006 Hz @ preferred 24 MHz clk_sys;
//        at default 20 MHz beam runs ~20.005 Hz until fit grants 24 MHz PLL).
//       Instantiates present_content_window (store map). Requires FRAME_W=1280
//       FRAME_H=720 in the same QSF enable recipe. Plex.sv wires geom_latch+mux.
//   `define PRESENT_BEAM_960     — present_beam_content_de true-DE (max tier 960×540)
//   `define PRESENT_MULTI_PIXEL  — 720p beam (COMPACT H1650 default) + present_npx_path (PPC)
//       Requires FRAME_W=1280 FRAME_H=720 (same store as L4). L4⊥MULTI beams,
//       but BOTH use the shared 720p DDR ABI via ddr_frame_abi_select.svh when
//       FRAME is 1280×720 (rd-duck: do not bind 720p bank only under L4).
//   `define PRESENT_PX_PER_CLK N — 1|2|4 with MULTI_PIXEL (default 1).
//                                  PPC=2 needs 40 Mpix/s capacity at 20 MHz for CEA
//                                  720p24 (29.7 Mpix/s). Store exposes rd_*_n ports.
//   `define PRESENT_CLK_PIX_PLL  — separate clk_pix + rate-match (optional)
//   `define PLEX_DDR_ABI_720P    — force 720p bank/doorbell even if FRAME≠1280×720
// Macros off → bit-identical Template H_DE=529 / DE_LAG=3 path (v0.3.0 baseline).
// Mutually exclusive: L4 vs BEAM_960 vs MULTI_PIXEL. Parent enables in fit QSF only.

`ifdef PRESENT_MULTI_PIXEL
	`ifndef PRESENT_PX_PER_CLK
		`define PRESENT_PX_PER_CLK 1
	`endif
`endif

`include "misterplex_clk_hz.svh"

module present_core #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter int FRAME_STRIDE = FRAME_W,
	parameter int SDRAM_REFRESH_CYCLES = 780,
	// Template/FBAR paint window (colorbars DE). Defaults reproduce v0.3.0 /
	// G-VID1 exactly: H_DE=529, V_STORE=240, scale ref 320×240, mul 39647.
	// These are NOT FRAME_W/FRAME_H — colorbars DE is fixed by the Template
	// path. Override only in simulation; product must keep defaults.
	parameter int TPL_H_DE = 529,
	parameter int TPL_V_STORE = 240,
	parameter int TPL_SCALE_REF_W = 320,
	parameter int TPL_SCALE_REF_H = 240,
	parameter int TPL_STORE_X_MUL = 39647,
	// L4 720p24 beam (used only under PLEX_PRESENT_720P_L4). Defaults match
	// w-clock NATIVE_720P kit. Product enable is QSF-gated default-off.
	parameter int L4_H_DE_P = 1280,
	parameter int L4_V_ACT_P = 720,
	parameter int L4_H_TOTAL_P = 1312,
	parameter int L4_V_TOTAL_P = 762,
	parameter int L4_H_FP_P = 8,
	parameter int L4_H_SW_P = 8,
	parameter int L4_V_FP_P = 8,
	parameter int L4_V_SW_P = 6,
`ifdef FRAME_CMD_FIFO_AW4
	parameter int FRAME_CMD_FIFO_AW = 4,
`elsif FRAME_CMD_FIFO_AW6
	parameter int FRAME_CMD_FIFO_AW = 6,
`else
	parameter int FRAME_CMD_FIFO_AW = 5,
`endif
`ifdef FRAME_LINES_1
	parameter int FRAME_LINE_COUNT = 1
`elsif FRAME_LINES_4
	parameter int FRAME_LINE_COUNT = 4
`elsif FRAME_LINES_8
	parameter int FRAME_LINE_COUNT = 8
`elsif FRAME_LINES_16
	parameter int FRAME_LINE_COUNT = 16
`else
	parameter int FRAME_LINE_COUNT = 4
`endif
)(
	input  wire        clk,
	input  wire        clk_sdram,
	input  wire        clk_audio,
	// Optional pix clock (PRESENT_CLK_PIX_PLL). Product ties to clk_sys.
	input  wire        clk_pix,
	input  wire        reset,

	input  wire        pal,
	input  wire        scandouble,
	input  wire [7:0]  content_fps,
	input  wire [7:0]  display_hz,
	input  wire [1:0]  pattern,
	input  wire        audio_en,        // OSD tone enable (when no FIFO audio)
	input  wire        use_frame_store, // OSD force bars when 1

	// Delivered content geometry (PLXG / future mux). 0 → max-tier fallback when
	// PRESENT_BEAM_960. Ignored on default Template path.
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,

	// frame_store write (from ingest)
	input  wire        fs_wr_en,
	input  wire [15:0] fs_wr_pixel,
	input  wire        fs_wr_reset,
	input  wire        fs_swap,
	output wire        fs_wr_ready,

	// SDRAM-backed frame_store port
	input  wire [15:0] sdram_dout,
	input  wire        sdram_ready,
	output wire        sdram_sel,
	output wire [26:1] sdram_addr,
	output wire [15:0] sdram_din,
	output wire        sdram_wr,
	output wire        sdram_rd,
	output wire  [1:0] sdram_bs,
	output wire        sdram_refresh,

`ifdef DDR_FRAME_STORE
	input  wire        ddr_start_req,
	input  wire        ddr_bank_sel,
	input  wire [15:0] ddr_status_osd,
	input  wire        ddr_input_cmd_valid,
	input  wire  [7:0] ddr_input_cmd,
	input  wire  [3:0] ddr_sdram_test_state,
	input  wire  [3:0] ddr_sdram_size_code,
	input  wire [15:0] ddr_sdram_error_count,
	input  wire        clk_ddr,
	output wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,
	output wire [15:0] ddr_frames_done,
	output wire        ddr_doorbell_ok,
`endif

	// audio_fifo write (from audio_ingest)
	input  wire        af_wr_en,
	input  wire [31:0] af_wr_data,
	input  wire        af_wr_flush,

	output wire        ce_pix,
	output wire        HBlank,
	output wire        HSync,
	output wire        VBlank,
	output wire        VSync,
	output wire [7:0]  r,
	output wire [7:0]  g,
	output wire [7:0]  b,

	output wire [15:0] audio_l,
	output wire [15:0] audio_r,

	output wire [31:0] stat_display_index,
	output wire [31:0] stat_content_index,
	output wire        stat_advance,
	output wire        stat_has_frame,
	output wire [31:0] stat_wr_count,
	output wire        stat_has_audio,
	output wire        stat_audio_underrun,
	output wire        stat_swap_pending,
	output wire [15:0] stat_frame_underruns,
	output wire  [7:0] stat_frame_sdram_state
);

	wire frame_start;
	wire advance;
	wire [31:0] disp_i, cont_i;

	present_cadence cadence (
		.clk(clk),
		.reset(reset),
		.display_tick(frame_start),
		.content_fps(content_fps),
		.display_hz(display_hz),
		.advance_unique(advance),
		.display_index(disp_i),
		.content_index(cont_i)
	);

	wire [7:0] br, bg, bb;
	wire       ce_pix_i, hb, hs, vb, vs, fstart;
	wire [9:0] hc, vc; // from colorbars — same counters as full-DE bar paint

	// Pattern encoding (status[7:6]): 0=None, 1=Bars, 2=Bars+Block, 3=Grid.
	// O[9] Force bars=Yes → always Bars (1), never None.
	wire [1:0] eff_pattern = use_frame_store ? 2'd1 : pattern;

	localparam int FRAME_X_W = $clog2(FRAME_W);
	localparam int FRAME_Y_W = $clog2(FRAME_H);

`ifdef PRESENT_MULTI_PIXEL
	localparam int PRESENT_PPC = `PRESENT_PX_PER_CLK;
`else
	localparam int PRESENT_PPC = 1;
`endif

	// ------------------------------------------------------------------
	// Always-on timing packs (noprune): survive map so post-fit hierarchy
	// can prove the 720p/960 generators are in the product netlist even
	// when BEAM/MULTI macros are off. Outputs are observational only on
	// the default path — they do not drive HDMI.
	// ------------------------------------------------------------------
	(* noprune *) wire [11:0] keep_720_hde, keep_720_htot, keep_720_vact, keep_720_vtot;
	(* noprune *) wire [11:0] keep_720_hss, keep_720_hse, keep_720_vss, keep_720_vse;
	(* noprune *) wire [15:0] keep_720_fps_milli;
	(* noprune *) wire        keep_720_needs_fast;
	present_video_timing_720p #(
		.CLK_PIX_HZ(`MISTERPLEX_CLK_PIX_HZ)
	) u_keep_timing_720p (
		.h_de(keep_720_hde),
		.h_total(keep_720_htot),
		.v_active(keep_720_vact),
		.v_total(keep_720_vtot),
		.h_sync_s(keep_720_hss),
		.h_sync_e(keep_720_hse),
		.v_sync_s(keep_720_vss),
		.v_sync_e(keep_720_vse),
		.fps_eff_milli(keep_720_fps_milli),
		.cea_24_needs_faster_pix(keep_720_needs_fast)
	);
	(* noprune *) wire [11:0] keep_960_hde, keep_960_htot, keep_960_vact, keep_960_vtot;
	(* noprune *) wire [11:0] keep_960_hss, keep_960_hse, keep_960_vss, keep_960_vse;
	(* noprune *) wire [15:0] keep_960_fps_milli;
	(* noprune *) wire        keep_960_mode30, keep_960_wide_fifo;
	present_video_timing_960 #(
		.MODE(0),
		.CLK_PIX_HZ(`MISTERPLEX_CLK_SYS_HZ)
	) u_keep_timing_960 (
		.h_de(keep_960_hde),
		.h_total(keep_960_htot),
		.v_active(keep_960_vact),
		.v_total(keep_960_vtot),
		.h_sync_s(keep_960_hss),
		.h_sync_e(keep_960_hse),
		.v_sync_s(keep_960_vss),
		.v_sync_e(keep_960_vse),
		.fps_eff_milli(keep_960_fps_milli),
		.mode_30hz(keep_960_mode30),
		.needs_wide_fifo(keep_960_wide_fifo)
	);

	// Always-on rate-match pack: proves Bresenham throttle + CEA F24 defaults
	// survive map. Observational only on default path (fire not wired to beam).
	(* noprune *) wire keep_rm_fire;
	present_pix_rate_match #(
		.F_SYS_HZ(`MISTERPLEX_CLK_SYS_HZ),
		.F_PIX_HZ(`MISTERPLEX_CEA720_F24_HZ),
		.PX_PER_CLK((`MISTERPLEX_PRESENT_PPC < 1) ? 1 : `MISTERPLEX_PRESENT_PPC)
	) u_keep_pix_rate_match (
		.clk(clk),
		.reset(reset),
		.in_ready(1'b1),
		.fire(keep_rm_fire)
	);

`ifdef PLEX_PRESENT_720P_L4
	// =====================================================================
	// L4 720p24 true-DE beam (DEFAULT OFF). w-clock: H=1312 V=762 @ 24 MHz
	// → 24.006 Hz (1:1 with measured PMS 24/1 asset; no pulldown).
	// =====================================================================
	// synthesis translate_off
	initial begin
		if (FRAME_W != 1280 || FRAME_H != 720)
			$error("PLEX_PRESENT_720P_L4 requires FRAME_W=1280 FRAME_H=720 (got %0d x %0d)",
				FRAME_W, FRAME_H);
`ifdef PRESENT_BEAM_960
		$error("PLEX_PRESENT_720P_L4 and PRESENT_BEAM_960 are mutually exclusive");
`endif
`ifdef PRESENT_MULTI_PIXEL
		$error("PLEX_PRESENT_720P_L4 and PRESENT_MULTI_PIXEL are mutually exclusive");
`endif
	end
	// synthesis translate_on

	// w-clock NATIVE_720P_GO_NOGO / Plex_native720p24.sdc — from module params
	localparam int L4_H_DE    = L4_H_DE_P;
	localparam int L4_V_ACT   = L4_V_ACT_P;
	localparam int L4_H_TOTAL = L4_H_TOTAL_P;
	localparam int L4_V_TOTAL = L4_V_TOTAL_P;
	localparam int L4_H_SYNC_S = L4_H_DE_P + L4_H_FP_P;
	localparam int L4_H_SYNC_E = L4_H_DE_P + L4_H_FP_P + L4_H_SW_P;
	localparam int L4_V_SYNC_S = L4_V_ACT_P + L4_V_FP_P;
	localparam int L4_V_SYNC_E = L4_V_ACT_P + L4_V_FP_P + L4_V_SW_P;

	wire [10:0] hc11, vc11, vtot_act11;
	wire [10:0] hde_act11, htot_act11, vact_act11;
	wire [10:0] beam_hde_req =
		(content_w == 11'd0) ? 11'(L4_H_DE) :
		(content_w > 11'(FRAME_W)) ? 11'(FRAME_W) : content_w;
	wire [10:0] beam_vact_req =
		(content_h == 11'd0) ? 11'(L4_V_ACT) :
		(content_h > 11'(FRAME_H)) ? 11'(FRAME_H) : content_h;
	wire [10:0] beam_htot_req = 11'(L4_H_TOTAL);
	wire [10:0] beam_vtot_req = 11'(L4_V_TOTAL);

	(* noprune *) present_beam_content_de #(
		.H_DE(L4_H_DE),
		.V_ACTIVE(L4_V_ACT),
		.H_TOTAL(L4_H_TOTAL),
		.V_TOTAL(L4_V_TOTAL),
		.H_SYNC_S(L4_H_SYNC_S),
		.H_SYNC_E(L4_H_SYNC_E),
		.V_SYNC_S(L4_V_SYNC_S),
		.V_SYNC_E(L4_V_SYNC_E)
	) u_beam_720p24 (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b1),
		.rt_vtotal(beam_vtot_req),
		.use_rt_geom(1'b1),
		.rt_h_de(beam_hde_req),
		.rt_h_total(beam_htot_req),
		.rt_v_active(beam_vact_req),
		.ce_pix(ce_pix_i),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart),
		.hc_out(hc11),
		.vc_out(vc11),
		.vtot_active(vtot_act11),
		.hde_active(hde_act11),
		.htot_active(htot_act11),
		.vact_active(vact_act11)
	);
	assign hc = hc11[9:0];
	assign vc = vc11[9:0];
	assign br = 8'd0;
	assign bg = 8'd0;
	assign bb = 8'd0;
	wire _unused_beam_scandouble = scandouble;
	wire _unused_beam_pal = pal;
	wire _unused_eff_pattern = |eff_pattern;
	wire _unused_l4_beam = (|vtot_act11) | (|htot_act11) | (|hde_act11) | (|vact_act11);

`elsif PRESENT_BEAM_960
	// =====================================================================
	// Ascal-native TRUE content DE. Default OFF. Replaces colorbars Template.
	// =====================================================================
	// synthesis translate_off
	initial begin
		if (FRAME_W != 960 || FRAME_H != 540)
			$error("PRESENT_BEAM_960 requires FRAME_W=960 FRAME_H=540 (got %0d x %0d)",
				FRAME_W, FRAME_H);
`ifdef PRESENT_MULTI_PIXEL
		$error("PRESENT_BEAM_960 and PRESENT_MULTI_PIXEL are mutually exclusive");
`endif
	end
	// synthesis translate_on

	wire [10:0] hc11, vc11, vtot_act11;
	wire [10:0] hde_act11, htot_act11, vact_act11;
	wire [10:0] beam_hde_req =
		(content_w == 11'd0) ? 11'd960 :
		(content_w > 11'(FRAME_W)) ? 11'(FRAME_W) : content_w;
	wire [10:0] beam_vact_req =
		(content_h == 11'd0) ? 11'd540 :
		(content_h > 11'(FRAME_H)) ? 11'(FRAME_H) : content_h;
	wire [10:0] beam_htot_req = 11'd1182;
	wire [10:0] beam_vtot_req = (content_fps <= 8'd25) ? 11'd705 : 11'd564;

	(* noprune *) present_beam_content_de #(
		.H_DE(960),
		.V_ACTIVE(540),
		.H_TOTAL(1182),
		.V_TOTAL(564),
		.H_SYNC_S(992),
		.H_SYNC_E(1056),
		.V_SYNC_S(548),
		.V_SYNC_E(554)
	) u_beam_960 (
		.clk(clk),
		.reset(reset),
		.use_rt_vtotal(1'b1),
		.rt_vtotal(beam_vtot_req),
		.use_rt_geom(1'b1),
		.rt_h_de(beam_hde_req),
		.rt_h_total(beam_htot_req),
		.rt_v_active(beam_vact_req),
		.ce_pix(ce_pix_i),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart),
		.hc_out(hc11),
		.vc_out(vc11),
		.vtot_active(vtot_act11),
		.hde_active(hde_act11),
		.htot_active(htot_act11),
		.vact_active(vact_act11)
	);
	assign hc = hc11[9:0];
	assign vc = vc11[9:0];
	assign br = 8'd0;
	assign bg = 8'd0;
	assign bb = 8'd0;
	wire _unused_beam_scandouble = scandouble;
	wire _unused_beam_pal = pal;
	wire _unused_eff_pattern = |eff_pattern;

`else
	// ---- Legacy Template path: colorbars H_DE=529 (FBAR) — product default ----
	colorbars bars (
		.clk(clk),
		.reset(reset),
		.pal(pal),
		.scandouble(scandouble),
		.content_index(cont_i),
		.pattern(eff_pattern),
		.ce_pix(ce_pix_i),
		.HBlank(hb),
		.HSync(hs),
		.VBlank(vb),
		.VSync(vs),
		.frame_start(fstart),
		.hc_out(hc),
		.vc_out(vc),
		.r(br),
		.g(bg),
		.b(bb)
	);
`endif

	localparam [FRAME_X_W-1:0] FRAME_LAST_X = FRAME_X_W'(FRAME_W - 1);
	localparam [FRAME_Y_W-1:0] FRAME_LAST_Y = FRAME_Y_W'(FRAME_H - 1);
	localparam [15:0] FRAME_LAST_X_16 = 16'(FRAME_W - 1);
	localparam [15:0] FRAME_LAST_Y_16 = 16'(FRAME_H - 1);

	// Stretch FRAME_W×FRAME_H frame_store across Template DE (colorbars hc/vc).
	//
	// Product (Plex.qsf FRAME_W=640 FRAME_H=480, forced scandouble):
	//   colorbars NTSC scandouble active vc=0..479 (VBlank asserts at vc==480).
	//   NATIVE_V_1TO1 maps store_y = vc with SCALE=1.0 so ALL FRAME_H rows are
	//   addressed (fixes the pre-T7 even-row-only ceiling: V_STORE=240 + scale 2.0).
	//
	// Legacy FRAME_H<=240 builds keep half-height py=(scandouble?vc>>1:vc) + scale
	// from a 240-line content window.
	//
	// Horizontal: H_DE stays 529 (FBAR Template class). Full 640 unique columns
	// require H_DE>=640, which is impossible at clk_sys=20 MHz / 60 Hz / 524 lines
	// (20e6/60/524 ≈ 636 clocks/line max; see test_present_store_scale_math).
	// STORE_X still samples 529 of FRAME_W via the 39647 mul-shift.
	//
	// L4 / BEAM_960 / MULTI override the map below; these localparams remain the
	// product-default Template path (macros off).
	localparam H_DE = 10'd529;
	localparam bit NATIVE_V_1TO1 = (FRAME_H > 240);
	localparam int V_STORE_I = NATIVE_V_1TO1 ? FRAME_H : 240;
	localparam [9:0] V_STORE = 10'(V_STORE_I);
	localparam [9:0] V_STORE_LAST = 10'(V_STORE_I - 1);
	// store_x ≈ floor(hc * FRAME_W / 529); 39647/65536 ≈ 320/529.
	localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE_I;
	// Beam Y for content + store. Native 480: use full vc (scandouble active 0..479).
	// Legacy 240: half when scandoubled so two display lines share one store row.
	wire [9:0] py = NATIVE_V_1TO1 ? vc : (scandouble ? (vc >> 1) : vc);
`ifdef PLEX_PRESENT_720P_L4
	// L4: present_content_window owns store map (identity when content==DE).
	// STORE domain tracks FRAME_* so QSF 1280×720 cannot disagree with 480p-era 1280/720 literals.
	wire in_content_l4 = ~hb & ~vb & (hc11 < hde_act11) & (vc11 < vact_act11);
	wire past_last_row; // driven by content_window
	wire [FRAME_X_W-1:0] store_x_clamped;
	wire [FRAME_Y_W-1:0] store_y_addr;
	wire de_r_win;
	// PIPE_DEPTH default=2 (mul | add+clamp). pipe_latency_ce for MP_STORE_LAT /
	// outer-reg accounting — L4 still has +1 store_x/y outer reg after this module.
	wire [3:0] content_window_pipe_lat_ce;
	(* noprune *) present_content_window #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.STORE_W(FRAME_W),
		.STORE_H(FRAME_H),
		.H_DE_DEFAULT(L4_H_DE),
		.V_DE_DEFAULT(L4_V_ACT)
		// PIPE_DEPTH default 2 — see present_content_window.sv
	) u_content_window (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix_i),
		.hc(hc11),
		.py(vc11),
		.in_content(in_content_l4),
		.win_enable(1'b1),
		.content_w(beam_hde_req),
		.content_h(beam_vact_req),
		.content_x0(11'd0),
		.content_y0(11'd0),
		.h_de(hde_act11),
		.v_de(vact_act11),
		.store_x(store_x_clamped),
		.store_y(store_y_addr),
		.de_r(de_r_win),
		.past_last_row(past_last_row),
		.pipe_latency_ce(content_window_pipe_lat_ce)
	);
	wire _unused_cw_pipe_lat = |content_window_pipe_lat_ce;
	wire in_content = in_content_l4;
	// Clamp from FRAME_H (not 239) so 720p does not inherit 480p last-row.
	wire [9:0] store_y_clamped =
		past_last_row ? 10'(FRAME_H > 0 ? FRAME_H - 1 : 0) : py;
	wire _unused_l4_win = de_r_win | |store_y_clamped;
`elsif PRESENT_BEAM_960
	wire in_content = ~hb & ~vb & (hc11 < hde_act11) & (vc11 < vact_act11);
	wire       past_last_row = (py >= 10'(FRAME_H));
	wire [9:0] store_y_clamped =
		past_last_row ? 10'(FRAME_H > 0 ? FRAME_H - 1 : 0) : py;
	wire [FRAME_X_W-1:0] store_x_clamped =
		(hc11 >= 11'(FRAME_W)) ? FRAME_LAST_X : FRAME_X_W'(hc11);
	wire [FRAME_Y_W-1:0] store_y_addr =
		(vc11 >= 11'(FRAME_H)) ? FRAME_LAST_Y : FRAME_Y_W'(vc11);
	wire _unused_beam_store_y_clamped = |store_y_clamped;
`else
	// Product default Template path (T7 native vertical @ FRAME_H=480).
	wire in_content = (hc < H_DE) && (py < V_STORE) && ~hb && ~vb;

	// Drive store_x from free-running hc (no blank-time force-to-0). Blank-time
	// reset handed column 0 to DE_LAG-delayed right-edge pixels (1 px wrap).
	wire [9:0] read_hc = hc;
	wire [31:0] store_x_prod = read_hc * STORE_X_SCALE;
	wire [15:0] store_x_comb = store_x_prod[31:16];
	wire [FRAME_X_W-1:0] store_x_clamped =
		(store_x_comb > FRAME_LAST_X_16) ? FRAME_LAST_X : store_x_comb[FRAME_X_W-1:0];

	// Clamp past the content window so an out-of-range row is never fetched.
	// colorbars can expose one surplus line vs VBlank edges; past_last_row also
	// feeds vb_d so that line is blanked (G-VID1 bottom-edge fix, generalized
	// from the hard-coded 240-row form to V_STORE).
	wire       past_last_row = (py >= V_STORE);
	wire [9:0] store_y_clamped = past_last_row ? V_STORE_LAST : py;
	wire [31:0] store_y_prod = store_y_clamped * STORE_Y_SCALE;
	wire [15:0] store_y_comb = store_y_prod[31:16];
	wire [FRAME_Y_W-1:0] store_y_addr =
		(store_y_comb > FRAME_LAST_Y_16) ? FRAME_LAST_Y : store_y_comb[FRAME_Y_W-1:0];
`endif

	reg [FRAME_X_W-1:0] store_x;
	reg [FRAME_Y_W-1:0] store_y;
	reg       de_r; // registered in_content for frame_store read align
	always @(posedge clk) begin
		if (reset) begin
			store_x <= 0;
			store_y <= '0;
			de_r    <= 1'b0;
		end else if (ce_pix_i) begin
			de_r    <= in_content;
			store_y <= store_y_addr;
			store_x <= store_x_clamped;
		end
	end

	// Frame-store read address mux. Default: Template-mapped store_x/y.
	// PRESENT_MULTI_PIXEL: beam glass coords + mp_fstart (assigned in MULTI block).
	wire [FRAME_X_W-1:0] fs_rd_x_w;
	wire [FRAME_Y_W-1:0] fs_rd_y_w;
	wire                 fs_rd_active_w;
	wire                 fs_vsync_w;
`ifndef PRESENT_MULTI_PIXEL
	assign fs_rd_x_w      = store_x;
	assign fs_rd_y_w      = store_y;
	assign fs_rd_active_w = de_r;
	assign fs_vsync_w     = fstart;
`endif

	wire [7:0] fr, fg, fb;
	wire       has_frame;
	wire       swap_pending;
	wire [31:0] wr_count;
	wire        wr_done;
	wire [15:0] frame_underruns;
	wire [7:0]  frame_sdram_state;

`ifdef DDR_FRAME_STORE
	assign fs_wr_ready = 1'b1;
	assign wr_count = 32'd0;
	assign wr_done = 1'b0;
	assign sdram_sel = 1'b0;
	assign sdram_addr = 26'd0;
	assign sdram_din = 16'd0;
	assign sdram_wr = 1'b0;
	assign sdram_rd = 1'b0;
	assign sdram_bs = 2'b11;
	assign sdram_refresh = 1'b0;

`include "ddr_frame_layout_params.svh"
	// Shared 720p/480p ABI: FRAME 1280×720 (L4 *or* MULTI) → 720p bank/doorbell.
	// rd-duck: L4-only ifdef left MULTI+CEA on 624×480 @ 0x30000000 — wrong.
	// Ternary CODED_W live in ddr_frame_abi_select.svh:
	//   DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_CODED_WIDTH : DDR_FRAME_CODED_WIDTH
`define DDR_FS_APPLY_LINE_FLOOR
`include "ddr_frame_abi_select.svh"
	// ONE agreed BW/ABI contract — CONSUMED into FS_* (not QIP-only dead localparams).
	// rd-duck: listing svh in files.qip alone ≠ fabric work.
	`include "plex_720p_bw_contract.svh"
	// 720p ABI: bind store geometry/ABI from P720_* contract (live parameters).
	// 480p ABI: keep DDR_FS_* path.
	localparam int FS_CODED_W     = DDR_FS_USE_720P_ABI ? P720_CODED_W : DDR_FS_CODED_W;
	localparam int FS_CODED_H     = DDR_FS_USE_720P_ABI ? P720_CODED_H : DDR_FS_CODED_H;
	localparam int FS_DISPLAY_W   = DDR_FS_DISPLAY_W;
	localparam int FS_DISPLAY_H   = DDR_FS_DISPLAY_H;
	localparam int FS_CROP_LEFT   = DDR_FS_CROP_LEFT;
	localparam int FS_CROP_TOP    = DDR_FS_CROP_TOP;
	localparam int FS_PRESENT_X   = DDR_FS_PRESENT_X;
	localparam int FS_PRESENT_Y   = DDR_FS_PRESENT_Y;
	localparam [31:0] FS_PHYS_BASE = DDR_FS_USE_720P_ABI ? P720_PHYS_BASE[31:0] : DDR_FS_PHYS_BASE;
	localparam int FS_BANK_STRIDE = DDR_FS_USE_720P_ABI ? P720_BANK_STRIDE : DDR_FS_BANK_STRIDE;
	localparam [31:0] FS_DOORBELL = DDR_FS_USE_720P_ABI ? P720_DOORBELL_PHYS[31:0] : DDR_FS_DOORBELL;
	// 720p ABI: floor LINE_COUNT at P720_LINE_COUNT (16); allow higher (e.g. 32).
	// Do not clamp max requests down to exactly 16 (rd-duck).
	localparam int FS_LINE_COUNT = DDR_FS_USE_720P_ABI
		? ((DDR_FS_LINE_COUNT > P720_LINE_COUNT) ? DDR_FS_LINE_COUNT : P720_LINE_COUNT)
		: DDR_FS_LINE_COUNT;

	// synthesis translate_off
	initial begin
		if (DDR_FS_USE_720P_ABI && (FS_LINE_COUNT < P720_LINE_COUNT))
			$error("present_core: FS_LINE_COUNT must be >= P720_LINE_COUNT floor");
		if (DDR_FS_USE_720P_ABI && (FS_CODED_W != P720_CODED_W || FS_CODED_H != P720_CODED_H))
			$error("present_core: FS_CODED must equal P720 coded");
		if (DDR_FS_USE_720P_ABI && (FS_BANK_STRIDE != P720_BANK_STRIDE))
			$error("present_core: FS_BANK_STRIDE must equal P720");
		if (DDR_FS_USE_720P_ABI && (FS_DOORBELL != P720_DOORBELL_PHYS))
			$error("present_core: FS_DOORBELL must equal P720");
		if (DDR_FS_USE_720P_ABI && (FS_PHYS_BASE != P720_PHYS_BASE))
			$error("present_core: FS_PHYS_BASE must equal P720");
		if (P720_FABRIC_RD_BPS != 33_177_600)
			$error("present_core: P720_FABRIC_RD_BPS must be 33177600");
	end
	// synthesis translate_on
	// Synthesis-ACTIVE contract gates (Quartus cannot ignore missing modules).
	generate
		if (P720_FABRIC_RD_BPS != 33_177_600) begin : g_p720_bps_gate
			p720_bw_contract_rd_bps_must_be_33177600 u_p720_bps_gate();
		end
		if (P720_I420_BYTES != 1_382_400) begin : g_p720_i420_gate
			p720_bw_contract_i420_must_be_1382400 u_p720_i420_gate();
		end
		if (P720_BEATS_PER_FRAME != 172_800) begin : g_p720_beats_gate
			p720_bw_contract_beats_must_be_172800 u_p720_beats_gate();
		end
	endgenerate
	// Synthesis-active keep: contract constants + live FS binds reach netlist.
	(* keep, noprune *) wire [31:0] p720_bw_contract_i420 = P720_I420_BYTES[31:0];
	(* keep, noprune *) wire [31:0] p720_bw_contract_rd_bps = P720_FABRIC_RD_BPS[31:0];
	(* keep, noprune *) wire [31:0] p720_bw_contract_stride = FS_BANK_STRIDE[31:0];
	(* keep, noprune *) wire [31:0] p720_bw_contract_doorbell = FS_DOORBELL[31:0];
	(* keep, noprune *) wire [31:0] p720_bw_contract_phys = FS_PHYS_BASE[31:0];
	(* keep, noprune *) wire [7:0]  p720_bw_contract_lines = FS_LINE_COUNT[7:0];

	// w-path compose: bank_geom + width_check + copy_budget stay in hierarchy when
	// 720p ABI is selected (not QIP-only dark silicon). M10K=0 each (source).
	// Refresh honesty: timing keep uses MISTERPLEX_CLK_PIX_HZ; without PLL,
	// CEA 1650×750 @ 20 MHz ≈ 16.16 Hz — geometry can PASS while refresh fails.
	generate
		if (DDR_FS_USE_720P_ABI) begin : g_path_720p_compose
			wire [31:0] geom_fb, geom_u, geom_v, geom_db;
			wire        geom_fits, geom_db_ok, geom_banks_ok, geom_pillar_ok, geom_chroma_ok;
			wire [15:0] geom_yqw, geom_cqw;
			ddr_i420_bank_geom #(
				.CODED_W(FS_CODED_W), .CODED_H(FS_CODED_H),
				.DISPLAY_W(FS_DISPLAY_W), .DISPLAY_H(FS_DISPLAY_H),
				.PRESENTED_W(FRAME_W), .PRESENTED_H(FRAME_H),
				.CROP_LEFT(FS_CROP_LEFT), .CROP_TOP(FS_CROP_TOP),
				.PILLAR_LEFT(FS_PRESENT_X), .PILLAR_RIGHT(0),
				.PHYS_BASE(FS_PHYS_BASE),
				.BANK_STRIDE_BYTES(FS_BANK_STRIDE),
				.DOORBELL_PHYS(FS_DOORBELL)
			) u_path_bank_geom (
				.y_plane_bytes(), .u_plane_offset(geom_u), .v_plane_offset(geom_v),
				.frame_bytes(geom_fb), .y_stride_bytes(), .chroma_stride_bytes(),
				.y_line_qwords(geom_yqw), .c_line_qwords(geom_cqw),
				.bank0_base(), .bank1_base(), .doorbell_phys(geom_db),
				.frame_fits_bank(geom_fits), .doorbell_eq_derived(geom_db_ok),
				.banks_below_doorbell(geom_banks_ok), .pillar_math_ok(geom_pillar_ok),
				.chroma_even_ok(geom_chroma_ok)
			);
			wire [15:0] wc_chroma_w, wc_chroma_h, wc_yqw;
			wire        wc_ok, wc_neg_u16, wc_neg_stride;
			ddr_i420_store_width_check #(
				.FRAME_W(FRAME_W), .FRAME_H(FRAME_H),
				.CODED_W(FS_CODED_W), .CODED_H(FS_CODED_H),
				.BANK_STRIDE_BYTES(FS_BANK_STRIDE),
				.PHYS_BASE(FS_PHYS_BASE)
			) u_path_width_check (
				.x_w_bits(), .y_w_bits(), .coded_x_w_bits(), .coded_y_w_bits(),
				.y_line_qwords(wc_yqw), .c_line_qwords(),
				.y_qw_aw_bits(), .c_qw_aw_bits(),
				.chroma_w(wc_chroma_w), .chroma_h(wc_chroma_h),
				.y_plane_bytes(), .u_plane_offset(), .v_plane_offset(),
				.frame_bytes(), .bank_stride_bytes(),
				.bank1_base(), .doorbell_phys(),
				.max_y_line_qword_off(), .max_c_line_qword_off(),
				.last_payload_byte_off(), .banks_in_reserved_window(),
				.dual_bank_fits_window(), .triple_bank_fits_window(),
				.bank_stride_ge_3x_ref480(), .frame_ge_3x_ref480(),
				.addr29_covers_bank1_end(), .plane_off_fits_u32(),
				.y_qw_aw_covers_line(), .c_qw_aw_covers_line(),
				.y_w_covers_height(), .x_w_covers_width(),
				.store_widths_ok(wc_ok),
				.naive_u16_frame_ok(wc_neg_u16), .naive_u16_y_plane_ok(),
				.naive_u7_y_line_qw_ok(), .naive_ref480_stride_fits(wc_neg_stride)
			);
			wire [31:0] bud_t_pl330, bud_t_fab;
			wire        bud_fab_contends, bud_pl330_contends_present;
			ddr_publish_copy_budget #(
				.FRAME_BYTES(P720_I420_BYTES),
				.FPS(P720_FPS)
			) u_path_copy_budget (
				.prereg_pl330_m10k(), .prereg_pl330_alm(),
				.prereg_fabric_bounce_m10k(), .prereg_fabric_alm_est(),
				.prereg_pl330_bw_kBps(), .prereg_fabric_peak_kBps(),
				.prereg_t_copy_arm_us(),
				.r_req_Bps(), .t_pl330_us(bud_t_pl330),
				.t_fabric_ideal_rw_us(bud_t_fab), .t_fabric_ideal_r_only_us(),
				.t_budget_24_us(),
				.pl330_beats_arm_copy(), .fabric_ideal_beats_arm(),
				.fabric_ideal_fits_24(), .pl330_est_fits_24(),
				.fabric_contends_present_port(bud_fab_contends),
				.pl330_contends_present_port(bud_pl330_contends_present),
				.pl330_contends_hps_cpu(), .dyn_base_zero_mover_m10k(),
				.pl330_bw_device_verified(), .fabric_real_ms_device_verified()
			);
			// Fold into keep chain so Quartus cannot strip (same pattern as bw contract).
			(* keep, noprune *) wire [31:0] path_compose_keep = geom_fb ^ geom_u ^ geom_v
				^ {16'd0, geom_yqw} ^ {16'd0, wc_chroma_w} ^ {16'd0, wc_chroma_h}
				^ bud_t_pl330 ^ bud_t_fab
				^ {31'd0, geom_fits & wc_ok & ~wc_neg_u16 & ~wc_neg_stride
					& bud_fab_contends & ~bud_pl330_contends_present};
		end
	endgenerate

`ifdef PRESENT_MULTI_PIXEL
	localparam int FS_PX_PER_CLK = PRESENT_PPC;
`else
	localparam int FS_PX_PER_CLK = 1;
`endif
	wire [FS_PX_PER_CLK*8-1:0] fs_rd_r_n, fs_rd_g_n, fs_rd_b_n;
	wire [FS_PX_PER_CLK-1:0]   fs_rd_lv_n;
	wire                       fs_rd_n_valid;

	// CODED_*: FS_* elaborated above (480p → DDR_FRAME_CODED_*; 720p ABI → 720P_*).
	ddr_frame_store #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.FRAME_STRIDE(FRAME_STRIDE),
		.CODED_W(FS_CODED_W),
		.CODED_H(FS_CODED_H),
		.DISPLAY_W(FS_DISPLAY_W),
		.DISPLAY_H(FS_DISPLAY_H),
		.CROP_LEFT(FS_CROP_LEFT),
		.CROP_TOP(FS_CROP_TOP),
		.PRESENT_X(FS_PRESENT_X),
		.PRESENT_Y(FS_PRESENT_Y),
		.LINE_COUNT(FS_LINE_COUNT),
		.PHYS_BASE(FS_PHYS_BASE),
		.HPS_BANK_STRIDE_BYTES(FS_BANK_STRIDE),
		.DOORBELL_PHYS(FS_DOORBELL),
		.PX_PER_CLK(FS_PX_PER_CLK)
	) fstore (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(fs_rd_x_w),
		.rd_y(fs_rd_y_w),
		.rd_active(fs_rd_active_w),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.rd_r_n(fs_rd_r_n),
		.rd_g_n(fs_rd_g_n),
		.rd_b_n(fs_rd_b_n),
		.rd_lane_valid_n(fs_rd_lv_n),
		.rd_n_valid(fs_rd_n_valid),
		.start_req(ddr_start_req),
		.bank_sel(ddr_bank_sel),
		.status_osd(ddr_status_osd),
		.input_cmd_valid(ddr_input_cmd_valid),
		.input_cmd(ddr_input_cmd),
		.sdram_test_state(ddr_sdram_test_state),
		.sdram_size_code(ddr_sdram_size_code),
		.sdram_error_count(ddr_sdram_error_count),
		.DDRAM_CLK(DDRAM_CLK),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.vsync_pulse(fs_vsync_w),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(frame_underruns),
		.frames_done(ddr_frames_done),
		.doorbell_ok(ddr_doorbell_ok),
		.debug_state(frame_sdram_state)
	);
`ifndef PRESENT_MULTI_PIXEL
	// N-wide ports exist at PX_PER_CLK=1 for port stability; scalar path uses rd_r/g/b.
	wire _unused_fs_npx = |{fs_rd_r_n, fs_rd_g_n, fs_rd_b_n, fs_rd_lv_n, fs_rd_n_valid};
`endif
`else
	frame_store #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.FRAME_STRIDE(FRAME_STRIDE),
		.REFRESH_CYCLES(SDRAM_REFRESH_CYCLES),
		.CMD_FIFO_AW(FRAME_CMD_FIFO_AW),
		.LINE_COUNT(FRAME_LINE_COUNT)
	) fstore (
		.clk(clk),
		.clk_sdram(clk_sdram),
		.reset(reset),
		.wr_en(fs_wr_en),
		.wr_pixel(fs_wr_pixel),
		.wr_reset_ptr(fs_wr_reset),
		.wr_ready(fs_wr_ready),
		.wr_count(wr_count),
		.wr_frame_done(wr_done),
		.rd_x(fs_rd_x_w),
		.rd_y(fs_rd_y_w),
		// Full content DE (registered); hold inside frame_store across !ce_pix
		.rd_active(fs_rd_active_w),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.sdram_dout(sdram_dout),
		.sdram_ready(sdram_ready),
		.sdram_sel(sdram_sel),
		.sdram_addr(sdram_addr),
		.sdram_din(sdram_din),
		.sdram_wr(sdram_wr),
		.sdram_rd(sdram_rd),
		.sdram_bs(sdram_bs),
		.sdram_refresh(sdram_refresh),
		// Request on DMA/F1 complete; apply only at display frame_start (vsync)
		.swap_banks(fs_swap),
		.vsync_pulse(fs_vsync_w),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(frame_underruns),
		.debug_state(frame_sdram_state)
	);
`endif

	// Product: once a frame is ingested, always show frame_store unless O[9] Force bars.
	// Pattern no longer steals cast (old pattern!=0 force caused bars/grid under video).
	// Pattern=None (0) + no frame → black (nothing “runs” behind cast).
	wire use_ext = has_frame && !use_frame_store;
	wire show_pattern = !use_ext && (use_frame_store || (pattern != 2'd0));
	// --- Align sync/blank to the pixel pipeline -------------------------------
	// hc -> fr costs 5 clk: store_x registers on ce_pix (2 clk) then frame_store
	// does rd_addr_r -> rd_q -> rd_r (3 clk). hc -> hb/hs costs only 1 clk. So the
	// RGB data is DE_LAG clk behind the sync it belongs to, which put the previous
	// line's last column in the first visible pixel (the 1 px left-edge wrap on VGA)
	// and blanked the true first column.
	//
	// Advancing the READ ADDRESS cannot fix this: during blank store_x is forced to
	// 0, so the blank-time prefetch is column 0 no matter what read_hc says. Delay
	// the sync/blank outputs instead — that aligns DE to the data by construction.
	// Only the HORIZONTAL sync/blank need this alignment: the pipeline delay is a few
	// clk, which is far shorter than a line, so delaying VBlank/VSync would only push
	// the bottom edge out and expose a row past the frame (the bottom bar).
	// DE_LAG=3 was measured, not guessed: scripts/gen_edge_markers.py paints the first
	// source column white and the last mid-grey, and scripts/check_edges.py captures
	// HDMI and reports where each landed. Sweeping 3..6 on hardware:
	//   3 -> col0 w=6px, col319 w=4px   (correct)
	//   4 -> col0 w=4px, col319 w=7px
	//   5 -> col0 MISSING, col319 w=11px
	//   6 -> col0 MISSING, col319 w=14px
	// Each extra clk of lag eats ~0.6 of a source column off the left and repeats it
	// on the right, which is precisely the right-edge "bar".
	localparam DE_LAG = 3'd3;
	reg [DE_LAG-1:0] hb_sr, hs_sr;
	always @(posedge clk) begin
		hb_sr <= {hb_sr[DE_LAG-2:0], hb};
		hs_sr <= {hs_sr[DE_LAG-2:0], hs};
	end
	wire hb_d = hb_sr[DE_LAG-1];
	wire hs_d = hs_sr[DE_LAG-1];
	wire vb_d = vb | past_last_row;
	wire vs_d = vs;

	// Gate the frame pixels with EXACTLY the delayed signal that drives VGA_DE.
	wire de_out = ~hb_d & ~vb_d;
	wire [7:0] leg_r = use_ext ? (de_out ? fr : 8'd0) : (show_pattern ? br : 8'd0);
	wire [7:0] leg_g = use_ext ? (de_out ? fg : 8'd0) : (show_pattern ? bg : 8'd0);
	wire [7:0] leg_b = use_ext ? (de_out ? fb : 8'd0) : (show_pattern ? bb : 8'd0);

`ifdef PRESENT_MULTI_PIXEL
	// ------------------------------------------------------------------
	// 720p multi-pixel path (macro ON only). Default OFF → leg_* above.
	// Beam defaults H_TOTAL=1650 V_TOTAL=750 = COMPACT fabric raster
	// (1650*750*24=29.7 MHz) — NOT CEA-861 720p24 VIC60 (H=3300 @ 59.4).
	// True CEA24 needs different beam totals + clk_pix; see clk_pix recipe.
	// Store exposes N-wide RGB (PX_PER_CLK); beam glass drives store address.
	// ------------------------------------------------------------------
	// synthesis translate_off
	initial begin
		if (!(PRESENT_PPC == 1 || PRESENT_PPC == 2 || PRESENT_PPC == 4))
			$error("PRESENT_MULTI_PIXEL requires PRESENT_PX_PER_CLK in {1,2,4} (got %0d)",
				PRESENT_PPC);
		if (FRAME_W != 1280 || FRAME_H != 720)
			$error("PRESENT_MULTI_PIXEL requires FRAME_W=1280 FRAME_H=720 for 720p DDR ABI (got %0d x %0d)",
				FRAME_W, FRAME_H);
`ifdef PRESENT_BEAM_960
		$error("PRESENT_MULTI_PIXEL and PRESENT_BEAM_960 are mutually exclusive");
`endif
`ifndef DDR_FRAME_STORE
		if (PRESENT_PPC > 1)
			$error("PRESENT_MULTI_PIXEL+PPC>1 requires DDR_FRAME_STORE (no scalar lane replicate)");
`endif
	end
	// synthesis translate_on

	// Synthesis-ACTIVE recipe gate (rd-duck FIT BLOCKER): PPC>1 without DDR store
	// must not elaborate. translate_off $error is ignored by Quartus.
	generate
		if (PRESENT_PPC > 1) begin : g_mp_ppc_needs_ddr
`ifndef DDR_FRAME_STORE
			// Intentional missing module → hard synth/elab fail (not sim-only).
			present_multi_ppc_requires_ddr_frame_store u_mp_ppc_ddr_gate();
`endif
		end
	endgenerate

	wire                mp_in_ready;
	wire                mp_beam_ce;
	wire [11:0]         mp_glass_x0, mp_glass_y;
	wire [PRESENT_PPC-1:0] mp_lane_de;
	wire                mp_hb, mp_hs, mp_vb, mp_vs, mp_fstart;
	wire                mp_out_ce;
	wire [7:0]          mp_out_r, mp_out_g, mp_out_b;
	wire                mp_out_hb, mp_out_hs, mp_out_vb, mp_out_vs, mp_out_fs;
	wire                mp_wr_full, mp_wr_af, mp_rd_ur, mp_rd_empty;

localparam int MP_CLK_PIX_HZ = `MISTERPLEX_CLK_PIX_HZ;
	localparam bit MP_INCLUDE_SYNC = 1'b1;

	// Live timing instance (in addition to keep_* packs) drives beam params via
	// parameters below — pack remains hierarchical proof of CEA constants.
	wire mp_beam_en = ~reset & mp_in_ready;
	present_beam_ppc #(
		.PX_PER_CLK(PRESENT_PPC),
		.H_DE(1280),
		.H_TOTAL(1650),
		.V_ACTIVE(720),
		.V_TOTAL(750),
		.H_SYNC_S(1390),
		.H_SYNC_E(1430),
		.V_SYNC_S(725),
		.V_SYNC_E(730)
	) u_mp_beam (
		.clk(clk),
		.reset(reset),
		.enable(mp_beam_en),
		.beam_ce(mp_beam_ce),
		.glass_x0(mp_glass_x0),
		.glass_y(mp_glass_y),
		.lane_de(mp_lane_de),
		.HBlank(mp_hb),
		.HSync(mp_hs),
		.VBlank(mp_vb),
		.VSync(mp_vs),
		.frame_start(mp_fstart)
	);

	// Identity-clamp glass → store; register on beam_ce (matches classic 1-cycle store_x).
	reg [FRAME_X_W-1:0] mp_store_x;
	reg [FRAME_Y_W-1:0] mp_store_y;
	reg                 mp_store_de;
	always @(posedge clk) begin
		if (reset) begin
			mp_store_x  <= '0;
			mp_store_y  <= '0;
			mp_store_de <= 1'b0;
		end else if (mp_beam_ce) begin
			// Widen glass (12b beam) to 16b before GT vs FRAME_LAST_*_16 (lint WIDTHEXPAND).
			mp_store_x  <= (16'(mp_glass_x0) > FRAME_LAST_X_16) ? FRAME_LAST_X
			             : mp_glass_x0[FRAME_X_W-1:0];
			mp_store_y  <= (16'(mp_glass_y) > FRAME_LAST_Y_16) ? FRAME_LAST_Y
			             : mp_glass_y[FRAME_Y_W-1:0];
			mp_store_de <= |mp_lane_de;
		end
	end
	assign fs_rd_x_w      = mp_store_x;
	assign fs_rd_y_w      = mp_store_y;
	assign fs_rd_active_w = mp_store_de;
	// Bank swap must track MULTI beam, not legacy Template fstart (rd-duck).
	assign fs_vsync_w     = mp_fstart;

	// N-wide store RGB (ddr_frame_store.PX_PER_CLK). PPC=1: lane0 == fr/fg/fb.
	// PPC>1: MUST use real dual-lane fs_rd_*_n — NEVER {PPC{fr}} replicate
	// (rd-duck FIT BLOCKER: replicate → half horizontal info while fit still greens).
`ifdef DDR_FRAME_STORE
	// Raw store buses (quality-gated below at push — do NOT ignore fs_rd_n_valid).
	wire [PRESENT_PPC*8-1:0] mp_store_r = fs_rd_r_n;
	wire [PRESENT_PPC*8-1:0] mp_store_g = fs_rd_g_n;
	wire [PRESENT_PPC*8-1:0] mp_store_b = fs_rd_b_n;
	wire [PRESENT_PPC-1:0]   mp_store_lv = fs_rd_lv_n;
	wire                     mp_store_nv = fs_rd_n_valid;
	// Synthesis-active keep: dual-lane buses + valid reach netlist under MULTI.
	(* keep, noprune *) wire [PRESENT_PPC*8-1:0] keep_mp_npx_r = mp_store_r;
	(* keep, noprune *) wire [PRESENT_PPC*8-1:0] keep_mp_npx_g = mp_store_g;
	(* keep, noprune *) wire [PRESENT_PPC*8-1:0] keep_mp_npx_b = mp_store_b;
	(* keep, noprune *) wire                     keep_mp_store_nv = mp_store_nv;
	(* keep, noprune *) wire [PRESENT_PPC-1:0]   keep_mp_store_lv = mp_store_lv;
	(* keep, noprune *) wire [FRAME_X_W-1:0] keep_mp_store_x = mp_store_x;
	(* keep, noprune *) wire [FRAME_Y_W-1:0] keep_mp_store_y = mp_store_y;
`else
	// PPC=1 only (gated above). Scalar passthrough — not a 720p product path.
	wire [PRESENT_PPC*8-1:0] mp_store_r = {PRESENT_PPC{fr}};
	wire [PRESENT_PPC*8-1:0] mp_store_g = {PRESENT_PPC{fg}};
	wire [PRESENT_PPC*8-1:0] mp_store_b = {PRESENT_PPC{fb}};
	wire [PRESENT_PPC-1:0]   mp_store_lv = {PRESENT_PPC{1'b1}};
	wire                     mp_store_nv = 1'b1;
`endif

	// Align beam sync tags to store response. MP_STORE_LAT is a *delay estimate*
	// (1 store_x reg + ddr RGB pipe); it is NOT a substitute for fs_rd_n_valid.
	// RGB/lane quality is gated by store valid at the delayed sample point
	// (rd-duck NACK: prior tip hard-coded LAT=4 and left fs_rd_n_valid unused).
	localparam int MP_STORE_LAT = 4;
	reg [MP_STORE_LAT-1:0] mp_tq_v;
	reg mp_tq_hb [0:MP_STORE_LAT-1];
	reg mp_tq_hs [0:MP_STORE_LAT-1];
	reg mp_tq_vb [0:MP_STORE_LAT-1];
	reg mp_tq_vs [0:MP_STORE_LAT-1];
	reg mp_tq_fs [0:MP_STORE_LAT-1];
	reg [PRESENT_PPC-1:0] mp_tq_lde [0:MP_STORE_LAT-1];
	integer mp_ti;
	always @(posedge clk) begin
		if (reset) begin
			mp_tq_v <= '0;
			for (mp_ti = 0; mp_ti < MP_STORE_LAT; mp_ti = mp_ti + 1) begin
				mp_tq_hb[mp_ti]  <= 1'b1;
				mp_tq_hs[mp_ti]  <= 1'b0;
				mp_tq_vb[mp_ti]  <= 1'b1;
				mp_tq_vs[mp_ti]  <= 1'b0;
				mp_tq_fs[mp_ti]  <= 1'b0;
				mp_tq_lde[mp_ti] <= '0;
			end
		end else begin
			for (mp_ti = MP_STORE_LAT-1; mp_ti > 0; mp_ti = mp_ti - 1) begin
				mp_tq_v[mp_ti]   <= mp_tq_v[mp_ti-1];
				mp_tq_hb[mp_ti]  <= mp_tq_hb[mp_ti-1];
				mp_tq_hs[mp_ti]  <= mp_tq_hs[mp_ti-1];
				mp_tq_vb[mp_ti]  <= mp_tq_vb[mp_ti-1];
				mp_tq_vs[mp_ti]  <= mp_tq_vs[mp_ti-1];
				mp_tq_fs[mp_ti]  <= mp_tq_fs[mp_ti-1];
				mp_tq_lde[mp_ti] <= mp_tq_lde[mp_ti-1];
			end
			mp_tq_v[0]   <= mp_beam_ce;
			mp_tq_hb[0]  <= mp_beam_ce ? mp_hb : 1'b1;
			mp_tq_hs[0]  <= mp_beam_ce ? mp_hs : 1'b0;
			mp_tq_vb[0]  <= mp_beam_ce ? mp_vb : 1'b1;
			mp_tq_vs[0]  <= mp_beam_ce ? mp_vs : 1'b0;
			mp_tq_fs[0]  <= mp_beam_ce ? mp_fstart : 1'b0;
			mp_tq_lde[0] <= mp_beam_ce ? mp_lane_de : '0;
		end
	end
	// Beam-timed push (sync always flows). Store valid gates RGB + lane quality.
	wire mp_push = mp_tq_v[MP_STORE_LAT-1];
	// When has_frame: require fs_rd_n_valid (group) and per-lane fs_rd_lv_n.
	// Miss → black RGB, lane_valid 0 (do not convert stale store data).
	// !has_frame → black, lane_valid 0 (blank).
	wire mp_store_rgb_ok = has_frame && mp_store_nv;
	wire [PRESENT_PPC*8-1:0] mp_npx_r = mp_store_rgb_ok ? mp_store_r : {PRESENT_PPC*8{1'b0}};
	wire [PRESENT_PPC*8-1:0] mp_npx_g = mp_store_rgb_ok ? mp_store_g : {PRESENT_PPC*8{1'b0}};
	wire [PRESENT_PPC*8-1:0] mp_npx_b = mp_store_rgb_ok ? mp_store_b : {PRESENT_PPC*8{1'b0}};
	wire [PRESENT_PPC-1:0]   mp_npx_lv =
		mp_tq_lde[MP_STORE_LAT-1]
		& (mp_store_rgb_ok ? mp_store_lv : {PRESENT_PPC{1'b0}});

`ifdef PRESENT_CLK_PIX_PLL
	(* noprune *) reg mp_rst_pix0, mp_rst_pix1;
	always @(posedge clk_pix or posedge reset) begin
		if (reset) begin
			mp_rst_pix0 <= 1'b1;
			mp_rst_pix1 <= 1'b1;
		end else begin
			mp_rst_pix0 <= 1'b0;
			mp_rst_pix1 <= mp_rst_pix0;
		end
	end
	wire mp_reset_pix = mp_rst_pix1;
`else
	wire mp_reset_pix = reset;
`endif

	present_npx_path #(
		.PX_PER_CLK(PRESENT_PPC),
		.FIFO_AW(6),
		.INCLUDE_SYNC(MP_INCLUDE_SYNC),
		.PREFILL_GROUPS(16)
	) u_mp_npx_path (
		.clk_sys(clk),
		.reset_sys(reset),
		.clk_pix(clk_pix),
		.reset_pix(mp_reset_pix),
		.in_valid(mp_push),
		.in_r(mp_npx_r),
		.in_g(mp_npx_g),
		.in_b(mp_npx_b),
		.in_lane_valid(mp_npx_lv),
		.in_hblank(mp_tq_hb[MP_STORE_LAT-1]),
		.in_hsync(mp_tq_hs[MP_STORE_LAT-1]),
		.in_vblank(mp_tq_vb[MP_STORE_LAT-1]),
		.in_vsync(mp_tq_vs[MP_STORE_LAT-1]),
		.in_fstart(mp_tq_fs[MP_STORE_LAT-1]),
		.in_ready(mp_in_ready),
		.out_ce(mp_out_ce),
		.out_r(mp_out_r),
		.out_g(mp_out_g),
		.out_b(mp_out_b),
		.out_hblank(mp_out_hb),
		.out_hsync(mp_out_hs),
		.out_vblank(mp_out_vb),
		.out_vsync(mp_out_vs),
		.out_fstart(mp_out_fs),
		.wr_full(mp_wr_full),
		.wr_almost_full(mp_wr_af),
		.rd_underrun(mp_rd_ur),
		.rd_empty(mp_rd_empty)
	);

	// Store read follows beam glass (mp_store_* → fs_rd_*_w). Needs FRAME_W/H
	// matching glass (1280×720) when this path is product-enabled.
	wire _unused_mp_glass = |{mp_wr_full, mp_wr_af, mp_rd_ur, mp_rd_empty, mp_out_fs};
	wire _unused_mp_clk_hz = (MP_CLK_PIX_HZ == 0);

	assign r = mp_out_r;
	assign g = mp_out_g;
	assign b = mp_out_b;
	assign ce_pix = mp_out_ce;
	assign HBlank = mp_out_hb;
	assign HSync  = mp_out_hs;
	assign VBlank = mp_out_vb;
	assign VSync  = mp_out_vs;
	assign frame_start = mp_out_fs;
	wire _unused_leg_rgb = |{leg_r, leg_g, leg_b, ce_pix_i, hb_d, hs_d, vb_d, vs_d, fstart};
`else
	assign r = leg_r;
	assign g = leg_g;
	assign b = leg_b;
	assign ce_pix = ce_pix_i;
	assign HBlank = hb_d;
	assign HSync  = hs_d;
	assign VBlank = vb_d;
	assign VSync  = vs_d;
	assign frame_start = fstart;
`endif

	// Silence unused keep packs on default path (still noprune for hierarchy).
	wire _unused_keep_timing = |{
		keep_720_hde, keep_720_htot, keep_720_vact, keep_720_vtot,
		keep_720_hss, keep_720_hse, keep_720_vss, keep_720_vse,
		keep_720_fps_milli, keep_720_needs_fast,
		keep_960_hde, keep_960_htot, keep_960_vact, keep_960_vtot,
		keep_960_hss, keep_960_hse, keep_960_vss, keep_960_vse,
		keep_960_fps_milli, keep_960_mode30, keep_960_wide_fifo,
		content_w, content_h, clk_pix
	};

	// --- Audio: FIFO preferred, else OSD tone ---
	wire [15:0] tone_l, tone_r;
	wire [15:0] fifo_l, fifo_r;
	wire        has_audio;
	wire        fifo_underrun;

	// Test tone only for debug/idle: never under product frames (cast). When
	// has_frame is set, silence the bars-style beep even if audio_fifo underruns
	// or F2 is skipped in favor of MrAudio.
	audio_tone tone (
		.clk_audio(clk_audio),
		.reset(reset),
		.enable(audio_en && !has_audio && !has_frame),
		.freq_div(16'd54),
		.sample_l(tone_l),
		.sample_r(tone_r),
		.underrun()
	);

	audio_fifo #(
		.DEPTH(2048)
	) afifo (
		.clk_wr(clk),
		.clk_rd(clk_audio),
		.reset(reset),
		.wr_en(af_wr_en),
		.wr_data(af_wr_data),
		.wr_flush(af_wr_flush),
		.wr_full(),
		.wr_level(),
		.rd_enable(1'b1),
		.sample_l(fifo_l),
		.sample_r(fifo_r),
		.underrun(fifo_underrun),
		.has_audio(has_audio)
	);

	assign audio_l = has_audio ? fifo_l : tone_l;
	assign audio_r = has_audio ? fifo_r : tone_r;

	assign stat_display_index = disp_i;
	assign stat_content_index = cont_i;
	assign stat_advance       = advance;
	assign stat_has_frame     = has_frame;
	assign stat_wr_count      = wr_count;
	assign stat_has_audio     = has_audio;
	assign stat_audio_underrun = fifo_underrun;
	assign stat_swap_pending  = swap_pending;
	assign stat_frame_underruns = frame_underruns;
	assign stat_frame_sdram_state = frame_sdram_state;

endmodule
