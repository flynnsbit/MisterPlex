// Present core: color bars OR external frame_store, cadence, tone + audio FIFO.
// Display owns VSync; unique content advances only when present_cadence says so.
//
// Multi-pixel present (720p path): see .agent-work/w-clock/MULTI_PIXEL_PRESENT_DESIGN.md
// and assets/multi_pixel_present_contract.json. Product default is 1 px/clk.
// `define PRESENT_MULTI_PIXEL  — connect beam → ddr N-wide → present_npx_path → RGB/CE
// `define PRESENT_PX_PER_CLK N — 1|2|4 (only meaningful with PRESENT_MULTI_PIXEL)
// `define PRESENT_CLK_PIX_PLL — separate clk_pix (outclk_3); rate-match + sync sideband
// `define PRESENT_BEAM_960 — ascal-native true-DE beam; 960×540 is MAX tier, runtime content_w/h
// Macros default OFF. Parent/w-nostub enables in fit grant QSF — not default shipping.

`ifdef PRESENT_MULTI_PIXEL
	`ifndef PRESENT_PX_PER_CLK
		`define PRESENT_PX_PER_CLK 2
	`endif
`endif

module present_core #(
	parameter int FRAME_W = 320,
	parameter int FRAME_H = 240,
	parameter int FRAME_STRIDE = FRAME_W,
	parameter int SDRAM_REFRESH_CYCLES = 780,
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
	// Optional separate pixel clock (PRESENT_CLK_PIX_PLL). When the macro is
	// off, Plex ties this to clk_sys; port exists so hierarchy stays stable.
	input  wire        clk_pix,
	input  wire        reset,

	input  wire        pal,
	input  wire        scandouble,
	input  wire [7:0]  content_fps,
	input  wire [7:0]  display_hz,
	input  wire [1:0]  pattern,
	input  wire        audio_en,        // OSD tone enable (when no FIFO audio)
	input  wire        use_frame_store, // OSD force bars when 1

	// Delivered content geometry (PLXG / plex_present_geom_mux). B13 true-DE.
	// 0 → fall back to max-tier 960×540. w-mem owns mailbox; we only consume.
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,

	// ---- w-mem / w-scaler ports (owner integrates; non-owners submit patches) ----
	// Fabric content window (w-scaler). win_enable=0 → beam identity / full FRAME.
	input  wire        win_enable = 1'b0,
	input  wire [10:0] content_x0 = 11'd0,
	input  wire [10:0] content_y0 = 11'd0,
	input  wire [10:0] win_h_de = 11'd0,
	input  wire [10:0] win_v_de = 11'd0,

	// Runtime DDR bank geometry + B16 live seq (w-mem latch). geom_enable=0 → legacy.
	input  wire        geom_enable = 1'b0,
	input  wire [15:0] geom_live_seq = 16'd0,
	input  wire        geom_live_valid = 1'b0,
	input  wire        q5_reserved_reject = 1'b0,
	input  wire [10:0] geom_coded_w = 11'd0,
	input  wire [10:0] geom_coded_h = 11'd0,
	input  wire [11:0] geom_y_stride = 12'd0,
	input  wire [10:0] geom_chroma_stride = 11'd0,
	input  wire [10:0] geom_display_w = 11'd0,
	input  wire [10:0] geom_display_h = 11'd0,
	input  wire [10:0] geom_present_x = 11'd0,
	input  wire [10:0] geom_present_y = 11'd0,
	input  wire [10:0] geom_crop_left = 11'd0,
	input  wire [10:0] geom_crop_top = 11'd0,

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
	output wire  [7:0] stat_frame_sdram_state,
	// B16: geometry transition blackout / hollow (w-mem store; raise HDMI_BLACKOUT)
	output wire        stat_geom_hold_black,
	output wire        stat_geom_hollow
);
`ifdef PRESENT_MULTI_PIXEL
	localparam int PRESENT_PPC = `PRESENT_PX_PER_CLK;
`else
	localparam int PRESENT_PPC = 1;
`endif

	wire frame_start;
	wire advance;
	wire [31:0] disp_i, cont_i;

	// ---- B20 two-phase visual geom (rd-duck: broader than beam DE) ----
	// Latch may promote PLXG live at raw VSync while store app_*/bank stay OLD
	// until swap_pending&&pending_ready. Display consumers MUST NOT free-run on
	// candidate: hold applied shadows until the same swap fire that commits bank.
	// Store still receives free-running candidate rt_* for cache prep (w-mem).
	// DAR/ascal live outside this module — OR stat_geom_hold_black into HDMI_BLACKOUT.
	wire        store_pending_ready;
	wire        swap_pending; // driven by fstore below (SV net)
	reg  [7:0]  app_content_fps;
	reg  [10:0] app_content_w;
	reg  [10:0] app_content_h;
	reg  [10:0] app_content_x0;
	reg  [10:0] app_content_y0;
	reg         app_win_enable;
	reg  [10:0] app_win_h_de;
	reg  [10:0] app_win_v_de;
	reg  [15:0] app_live_seq;
	reg         app_live_valid;
	// Update qualifier — defined with B20 beam block (swap_fire / free / idle).
	wire        visual_geom_apply;
	wire        b20_visual_hold;

	// Film vs TV class for beam V_TOTAL and BEAM_960 cadence Hz (rd-duck B15).
	// fps<=24 → film ~24.0007 (V=705). fps>=25 → TV ~30.0008 (V=564).
	// 25 must NOT fall into film (host may publish valid 25).
	// INTEGER content_fps only (q5). NTSC 24000/1001 bucketed to 24 is ~1028 ppm
	// fast vs true 23.976 — NOT source-locked (ntsc_rational_cadence_wall.json).
	// Use APPLIED fps (not free-running candidate) so film↔TV class cannot race bank.
	wire beam_film_class = (app_content_fps <= 8'd24);

	// Cadence display_hz must match the *tick source* rate (rd-duck B15).
	// BEAM_960: frame_start is core raster @24/30, NOT HDMI 50/60. Passing 60
	// with content_fps=30 yields advance_unique ~15/s (wrong). Ascal owns glass
	// 2:1/5:2 repeat. Pass core Hz: fps==24/30 ⇒ 1:1; fps=25 on 30-core is
	// floor(n*25/30) hold (NOT 1:1 — content_fps != cadence_display_hz).
	// Legacy non-beam: keep top-level display_hz (50/60).
	// NOTE: DDR bank swap uses vsync_pulse=fstart && swap_pending — NOT advance.
	// advance still feeds colorbars content_index + stat_advance only (C1).
`ifdef PRESENT_BEAM_960
	wire [7:0] cadence_display_hz = beam_film_class ? 8'd24 : 8'd30;
`else
	wire [7:0] cadence_display_hz = display_hz;
`endif
	present_cadence cadence (
		.clk(clk),
		.reset(reset),
		.display_tick(frame_start),
		.content_fps(app_content_fps),
		.display_hz(cadence_display_hz),
		.advance_unique(advance),
		.display_index(disp_i),
		.content_index(cont_i)
	);

	wire [7:0] br, bg, bb;
	wire       ce_pix_i, hb, hs, vb, vs, fstart;
	// Pattern encoding (status[7:6]): 0=None, 1=Bars, 2=Bars+Block, 3=Grid.
	// O[9] Force bars=Yes → always Bars (1), never None.
	wire [1:0] eff_pattern = use_frame_store ? 2'd1 : pattern;
	wire _unused_scandouble_port = scandouble;
	wire _unused_pal = pal;

	localparam int FRAME_X_W = $clog2(FRAME_W);
	localparam int FRAME_Y_W = $clog2(FRAME_H);
	localparam [FRAME_X_W-1:0] FRAME_LAST_X = FRAME_X_W'(FRAME_W - 1);
	localparam [FRAME_Y_W-1:0] FRAME_LAST_Y = FRAME_Y_W'(FRAME_H - 1);
	localparam [15:0] FRAME_LAST_X_16 = 16'(FRAME_W - 1);
	localparam [15:0] FRAME_LAST_Y_16 = 16'(FRAME_H - 1);

	reg [FRAME_X_W-1:0] store_x;
	reg [FRAME_Y_W-1:0] store_y;
	reg       de_r;
	wire       past_last_row;
	wire       in_content;

	// ---- B20 visual two-phase (all paths; not BEAM-only) ----
	// Latch may promote PLXG at VSync while store bank stays OLD until
	// swap_pending&&pending_ready. Hold applied DE/fps/window/seq until that fire.
`ifdef DDR_FRAME_STORE
	wire beam_swap_fire_g = swap_pending && store_pending_ready;
	wire beam_de_free_g   = !use_frame_store;
	wire beam_de_idle_g   = use_frame_store && !swap_pending &&
	                       ((content_w == 11'd0) || !geom_enable);
`ifdef FAULT_B20_VISUAL_FREE_RUN
	assign visual_geom_apply = 1'b1;
`else
	assign visual_geom_apply = beam_de_free_g || beam_swap_fire_g || beam_de_idle_g;
`endif
`else
	assign visual_geom_apply = 1'b1;
	assign store_pending_ready = 1'b1;
`endif

	always @(posedge clk) begin
		if (reset) begin
			app_content_fps <= 8'd24;
			app_content_w   <= 11'd0;
			app_content_h   <= 11'd0;
			app_content_x0  <= 11'd0;
			app_content_y0  <= 11'd0;
			app_win_enable  <= 1'b0;
			app_win_h_de    <= 11'd0;
			app_win_v_de    <= 11'd0;
			app_live_seq    <= 16'd0;
			app_live_valid  <= 1'b0;
		end else if (visual_geom_apply) begin
			app_content_fps <= content_fps;
			app_content_w   <= content_w;
			app_content_h   <= content_h;
			app_content_x0  <= content_x0;
			app_content_y0  <= content_y0;
			app_win_enable  <= win_enable;
			app_win_h_de    <= win_h_de;
			app_win_v_de    <= win_v_de;
			app_live_seq    <= geom_live_seq;
			app_live_valid  <= geom_live_valid;
		end
	end

`ifdef FAULT_B20_VISUAL_FREE_RUN
	assign b20_visual_hold = 1'b0;
`else
`ifdef DDR_FRAME_STORE
	assign b20_visual_hold = use_frame_store && geom_live_valid && geom_enable &&
		(geom_live_seq != app_live_seq);
`else
	assign b20_visual_hold = 1'b0;
`endif
`endif

`ifdef PRESENT_BEAM_960
	// =====================================================================
	// Ascal-native TRUE content DE (w-clock / w-scaler). Default OFF.
	// Do NOT implement BEAM_960 by parameterizing MULTI_PIXEL/npx (rd-duck):
	// that path has FIFO LAT+prefill; this path is 1px CE=1 + DE_LAG only.
	// Replaces colorbars Template H_DE=529. Identity store: rd_x=hc, rd_y=vc.
	// Requires FRAME_W=960, FRAME_H=540 (QSF `FRAME_W=960` etc.).
	// Bank swap uses this beam's fstart (not colorbars).
	// Mutually exclusive with PRESENT_MULTI_PIXEL for first-fit (ascal path).
	// =====================================================================
	// synthesis translate_off
	initial begin
		if (FRAME_W != 960 || FRAME_H != 540)
			$error("PRESENT_BEAM_960 requires FRAME_W=960 FRAME_H=540 (got %0d x %0d)",
				FRAME_W, FRAME_H);
`ifdef PRESENT_MULTI_PIXEL
		$error("PRESENT_BEAM_960 and PRESENT_MULTI_PIXEL are mutually exclusive (first fit ascal path)");
`endif
	end
	// synthesis translate_on

	// B2b: present_beam_content_de is the ONLY raster SoT.
	// B13: runtime true-DE from content_w/h (PLXG-delivered). 960×540 = max tier
	// defaults only — not a fixed product raster (96.5% of library is smaller).
	// Frame-boundary latch inside beam (rd-duck). Totals stay 1182×564@30 /
	// 1182×705@24 for ascal-friendly blanking independent of active size.
	wire [10:0] hc11, vc11, vtot_act11;
	wire [10:0] hde_act11, htot_act11, vact_act11;

	// Clamp content into bank max; 0 → max-tier fallback (idle/bars only).
	// Mux native→legacy disable must emit content 624×480, not 0 (island if 0→960).
	// Product: DE from applied shadow. FAULT_B20_* free-run uses candidate (RED).
`ifdef FAULT_B20_BEAM_FREE_RUN
	wire [10:0] beam_src_w = content_w;
	wire [10:0] beam_src_h = content_h;
`else
`ifdef FAULT_B20_VISUAL_FREE_RUN
	wire [10:0] beam_src_w = content_w;
	wire [10:0] beam_src_h = content_h;
`else
	wire [10:0] beam_src_w = app_content_w;
	wire [10:0] beam_src_h = app_content_h;
`endif
`endif
	wire [10:0] beam_hde_req =
		(beam_src_w == 11'd0) ? 11'd960 :
		(beam_src_w > 11'(FRAME_W)) ? 11'(FRAME_W) : beam_src_w;
	wire [10:0] beam_vact_req =
		(beam_src_h == 11'd0) ? 11'd540 :
		(beam_src_h > 11'(FRAME_H)) ? 11'(FRAME_H) : beam_src_h;
	// Fixed line class @20 MHz: 1182 clocks/line. V_TOTAL selects 30 vs 24 Hz.
	// beam_film_class from app_content_fps (shared with cadence_display_hz).
	// Fixed line class @20 MHz: 1182 clocks/line. V_TOTAL selects 30 vs 24 Hz.
	// beam_film_class from app_content_fps. B20 apply/hold is above (all paths).
	wire [10:0] beam_htot_req = 11'd1182;
	wire beam_de_apply = 1'b1;

	// Bresenham V_TOTAL: exact long-run NTSC (default) or fixed under FAULT.
	// Updates on fstart after beam latches current vtot (registered).
	wire [10:0] beam_vtot_bres;
	wire        beam_vtot_hi;
	present_vtotal_bresenham u_vtot_bres (
		.clk(clk),
		.reset(reset),
		.enable(1'b1),
		.film_class(beam_film_class),
		.frame_tick(fstart),
		.vtotal_out(beam_vtot_bres),
		.v_lo_out(),
		.v_hi_out(),
		.chose_hi(beam_vtot_hi)
	);
	wire [10:0] beam_vtot_req = beam_vtot_bres;
	wire _unused_vtot_hi = beam_vtot_hi;

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
		// B13 ON: drive runtime ports from delivered content_w/h.
		.use_rt_vtotal(1'b1),
		.rt_vtotal(beam_vtot_req),
		.use_rt_geom(1'b1),
		.rt_h_de(beam_hde_req),
		.rt_h_total(beam_htot_req),
		.rt_v_active(beam_vact_req),
		.rt_de_apply(beam_de_apply),
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

	// Identity map: DE extent == latched content (true_de). No /529 stretch.
	// hde_act/vact_act track content_w/h via use_rt_geom (B13).
	assign in_content = (hc11 < hde_act11) && (vc11 < vact_act11) && ~hb && ~vb;
	assign past_last_row = (vc11 >= vact_act11);
	wire [FRAME_X_W-1:0] store_x_id =
		(hc11 >= 11'(FRAME_W)) ? FRAME_LAST_X : FRAME_X_W'(hc11);
	wire [FRAME_Y_W-1:0] store_y_id =
		(vc11 >= 11'(FRAME_H)) ? FRAME_LAST_Y : FRAME_Y_W'(vc11);

	always @(posedge clk) begin
		if (reset) begin
			store_x <= '0;
			store_y <= '0;
			de_r    <= 1'b0;
		end else if (ce_pix_i) begin
			de_r    <= in_content;
			store_x <= store_x_id;
			store_y <= store_y_id;
		end
	end

	// Pattern RGB without colorbars (force-bars / idle).
	assign br = hc11[7:0] ^ {6'b0, eff_pattern};
	assign bg = vc11[7:0];
	assign bb = 8'h40;
	// Anti-DCE: beam counters + active vtotal must survive map.
	wire _unused_beam960 = (|hc11) | (|vc11) | (|vtot_act11)
		| (|hde_act11) | (|htot_act11) | (|vact_act11) | ce_pix_i
		| (|content_w) | (|content_h) | (|beam_hde_req) | (|beam_vact_req);

`else
	// ---- Legacy Template path: colorbars H_DE=529 (FBAR) ----
	wire _unused_content_geom = |content_w | |content_h;
	wire [9:0] hc, vc;

	localparam bit PRODUCT_V_480 = 1'b1;

	colorbars bars (
		.clk(clk),
		.reset(reset),
		.pal(pal),
		.scandouble(PRODUCT_V_480),
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

	// Stretch FRAME_W×FRAME_H across Template DE=529.
	localparam H_DE    = 10'd529;
	localparam int V_STORE = FRAME_H;
	localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE;

	wire [9:0] py = vc;
	wire [9:0] v_store = 10'(V_STORE);
	assign in_content = (hc < H_DE) && (py < v_store) && ~hb && ~vb;
	wire [9:0] read_hc = hc;
	wire [31:0] store_x_prod = read_hc * STORE_X_SCALE;
	wire [15:0] store_x_comb = store_x_prod[31:16];
	wire [FRAME_X_W-1:0] store_x_clamped =
		(store_x_comb > FRAME_LAST_X_16) ? FRAME_LAST_X : store_x_comb[FRAME_X_W-1:0];

	assign past_last_row = (py >= v_store);
	wire [9:0] store_y_clamped = past_last_row ? (v_store - 10'd1) : py;
	wire [31:0] store_y_scale = 32'(STORE_Y_SCALE);
	wire [31:0] store_y_prod = store_y_clamped * store_y_scale;
	wire [15:0] store_y_comb = store_y_prod[31:16];
	wire [FRAME_Y_W-1:0] store_y_addr =
		(store_y_comb > FRAME_LAST_Y_16) ? FRAME_LAST_Y : store_y_comb[FRAME_Y_W-1:0];

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
`endif

	wire [7:0] fr, fg, fb;
	wire       has_frame;
	// swap_pending declared earlier (B20 visual two-phase); driven by fstore.
	wire [31:0] wr_count;
	wire        wr_done;
	wire [15:0] frame_underruns;
	wire [7:0]  frame_sdram_state;
	// B16 from ddr_frame_store when DDR_FRAME_STORE_RUNTIME_GEOM (w-mem store).
	wire       geom_hold_black;
	wire       geom_hollow_fault;
	// Keep window/geom ports referenced so unused-input elision cannot drop them.
	wire _keep_win_geom_ports =
		win_enable | (|content_x0) | (|content_y0) | (|win_h_de) | (|win_v_de)
		| geom_enable | (|geom_live_seq) | geom_live_valid | q5_reserved_reject
		| (|geom_coded_w) | (|geom_coded_h) | (|geom_y_stride) | (|geom_chroma_stride)
		| (|geom_display_w) | (|geom_display_h) | (|geom_present_x) | (|geom_present_y)
		| (|geom_crop_left) | (|geom_crop_top);

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

	// N-wide frame-store ports (PPC=1 ⇒ rd_*_n is scalar passthrough).
	wire [PRESENT_PPC*8-1:0] fs_r_n, fs_g_n, fs_b_n;
	wire [PRESENT_PPC-1:0]   fs_lane_v_n;
	wire                     fs_n_valid;

`ifdef PRESENT_MULTI_PIXEL
	// ------------------------------------------------------------------
	// Multi-pixel 1280×720 video mode (macro ON only).
	// Default build leaves this ifdef off → colorbars H_DE=529 Template
	// (FBAR/DE_LAG) is UNTOUCHED. Do not move H_DE=529 without parent grant.
	//
	// Beam (CEA 720p geometry) → store read at glass_x0 → N-wide RGB →
	// present_npx_path wide-group FIFO → 1 px/clk (prefill+skid).
	// Same-clock bring-up: clk_pix==clk, beam backpressured by in_ready.
	// PRESENT_CLK_PIX_PLL: Bresenham rate-match to F_PIX + FIFO sync sideband
	// so line time matches clk_pix (see CLK_PIX_PLL_PLAN.md).
	//
	// H ownership: beam steps glass_x0 by PPC (w-clock). w-scaler maps
	// glass→store and supplies Y qword+1 for straddle; active 1280 DE with
	// x0%PPC==0 does not straddle for PPC in {2,4}.
	// ------------------------------------------------------------------
	wire                mp_in_ready;
	wire                mp_beam_ce;
	wire [11:0]         mp_glass_x0, mp_glass_y;
	wire [PRESENT_PPC-1:0] mp_lane_de;
	wire                mp_hb, mp_hs, mp_vb, mp_vs, mp_fstart;
	wire                mp_out_ce;
	wire [7:0]          mp_out_r, mp_out_g, mp_out_b;
	wire                mp_out_hb, mp_out_hs, mp_out_vb, mp_out_vs, mp_out_fs;
	wire                mp_wr_full, mp_wr_af, mp_rd_ur, mp_rd_empty;

`ifdef PRESENT_CLK_PIX_PLL
`ifdef PRESENT_CLK_PIX_30
	// PIX30 glass content rate (not held fit). Requires PRESENT_CLK_PIX_PLL.
	localparam int MP_CLK_PIX_HZ = 37_125_000;
`else
	localparam int MP_CLK_PIX_HZ = 29_700_000; // PIX24 held fit
`endif
`else
	localparam int MP_CLK_PIX_HZ = 20_000_000;
`endif
	// ALWAYS pack H/V/fstart with RGB through the FIFO (rd-duck same-clock trap).
	// INCLUDE_SYNC=0 + direct mp_hb/mp_vs left H/V leading RGB by LAT+PREFILL.
	// Same-clock and PLL both consume FIFO sidebands — never beam-direct sync.
	localparam bit MP_INCLUDE_SYNC = 1'b1;

	// Timing constants + effective refresh at CLK_PIX_HZ.
	// keep/noprune: mode must survive map for post-fit hierarchy checks.
	(* noprune *) wire [11:0] mp_h_de, mp_h_total, mp_v_act, mp_v_total;
	(* noprune *) wire [11:0] mp_hs_s, mp_hs_e, mp_vs_s, mp_vs_e;
	(* noprune *) wire [15:0] mp_fps_milli;
	(* noprune *) wire        mp_needs_fast_pix;
	present_video_timing_720p #(
		.CLK_PIX_HZ(MP_CLK_PIX_HZ)
	) u_mp_timing (
		.h_de(mp_h_de),
		.h_total(mp_h_total),
		.v_active(mp_v_act),
		.v_total(mp_v_total),
		.h_sync_s(mp_hs_s),
		.h_sync_e(mp_hs_e),
		.v_sync_s(mp_vs_s),
		.v_sync_e(mp_vs_e),
		.fps_eff_milli(mp_fps_milli),
		.cea_24_needs_faster_pix(mp_needs_fast_pix)
	);

`ifdef PRESENT_CLK_PIX_PLL
	// Producer LEAD: average slightly above nominal clk_pix so the FIFO runs
	// near the high-water / backpressure side. Equal averages + ppm drift will
	// eventually underrun a finite FIFO; overflow can throttle via in_ready,
	// underflow cannot. Lead is absorbed by skid/async almost_full.
	// 1000 ppm lead: PIX24 → 29_729_700; PIX30 → 37_162_125 px/s equiv.
	localparam int MP_PROD_LEAD_PPM = 1000;
	localparam int MP_RATE_PIX_HZ =
		MP_CLK_PIX_HZ + (MP_CLK_PIX_HZ / (1_000_000 / MP_PROD_LEAD_PPM));
	wire mp_rate_fire;
	present_pix_rate_match #(
		.F_SYS_HZ(20_000_000),
		.F_PIX_HZ(MP_RATE_PIX_HZ),
		.PX_PER_CLK(PRESENT_PPC)
	) u_mp_rate (
		.clk(clk),
		.reset(reset),
		.in_ready(mp_in_ready),
		.fire(mp_rate_fire)
	);
	wire mp_beam_en = ~reset & mp_in_ready & mp_rate_fire;
`else
	wire mp_beam_en = ~reset & mp_in_ready;
`endif

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

	// Store map: IDENTITY glass→store clamp.
	// Glass DE is always 1280×720 under this arm. FRAME_* is the *store/source*
	// canvas (product path: 960×540, not 1280). Identity is valid ONLY when
	// FRAME_W==1280 && FRAME_H==720 (native-source banks). Otherwise glass x/y
	// past FRAME_LAST clamp → right/bottom smear — NOT a 4/3 upscale.
	// w-scaler owns non-identity maps (present_content_window). Do NOT naive-scale
	// only glass_x0: ddr N-wide yuv extracts consecutive store px src_x0..+PPC-1.
	// See .agent-work/w-clock/SOURCE_VS_OUTPUT_GEOM_SWEEP.md
	// MP_IDENTITY_FRAME_EQ_GLASS (gate string — do not rename lightly)
	localparam int MP_GLASS_W = 1280;
	localparam int MP_GLASS_H = 720;
	localparam bit MP_IDENTITY_FRAME_EQ_GLASS =
		(FRAME_W == MP_GLASS_W) && (FRAME_H == MP_GLASS_H);
	// synthesis translate_off
	initial begin
		if (!MP_IDENTITY_FRAME_EQ_GLASS)
			$error("PRESENT_MULTI_PIXEL identity store map requires FRAME %0dx%0d (glass); got %0dx%0d — need w-scaler glass→store (product 960x540 source)",
				MP_GLASS_W, MP_GLASS_H, FRAME_W, FRAME_H);
	end
	// synthesis translate_on
	(* noprune *) wire mp_identity_geom_ok = MP_IDENTITY_FRAME_EQ_GLASS;
	wire [FRAME_X_W-1:0] mp_store_x =
		(mp_glass_x0 > 12'(FRAME_LAST_X)) ? FRAME_LAST_X
			: mp_glass_x0[FRAME_X_W-1:0];
	wire [FRAME_Y_W-1:0] mp_store_y =
		(mp_glass_y > 12'(FRAME_LAST_Y)) ? FRAME_LAST_Y
			: mp_glass_y[FRAME_Y_W-1:0];
	wire mp_de_any = |mp_lane_de;

	// Register beam→store one cycle (align with product store_x style).
	reg [FRAME_X_W-1:0] mp_store_x_r;
	reg [FRAME_Y_W-1:0] mp_store_y_r;
	reg                 mp_de_r;
	reg [PRESENT_PPC-1:0] mp_lane_de_r;
	always @(posedge clk) begin
		if (reset) begin
			mp_store_x_r <= '0;
			mp_store_y_r <= '0;
			mp_de_r      <= 1'b0;
			mp_lane_de_r <= '0;
		end else if (mp_beam_ce) begin
			mp_store_x_r <= mp_store_x;
			mp_store_y_r <= mp_store_y;
			mp_de_r      <= mp_de_any;
			mp_lane_de_r <= mp_lane_de;
		end
	end

	wire [FRAME_X_W-1:0] fstore_rd_x = mp_store_x_r;
	wire [FRAME_Y_W-1:0] fstore_rd_y = mp_store_y_r;
	wire                 fstore_rd_a = mp_de_r;
`else
	wire [FRAME_X_W-1:0] fstore_rd_x = store_x;
	wire [FRAME_Y_W-1:0] fstore_rd_y = store_y;
	wire                 fstore_rd_a = de_r;
`endif

	// B7 Option-C 720p map constants (must match w-mem ddr_frame_layout / host).
	// Prefer included params when present; else parent-verified literals.
`ifdef DDR_FRAME_720P_PHYS_BASE
	localparam [31:0] PC_PHYS_BASE_720P = DDR_FRAME_720P_PHYS_BASE;
	localparam int    PC_STRIDE_720P    = DDR_FRAME_720P_YUV420P_BANK_STRIDE;
	localparam [31:0] PC_DOORBELL_720P  = DDR_FRAME_720P_YUV420P_DOORBELL_PHYS;
`else
	localparam [31:0] PC_PHYS_BASE_720P = 32'h3018_0000;
	localparam int    PC_STRIDE_720P    = 32'h0018_0000;
	localparam [31:0] PC_DOORBELL_720P  = 32'h3047_F000;
`endif

	// Store connect policy (parent arbitration #3):
	//   DDR_FRAME_STORE_RUNTIME_GEOM — w-mem store with B7 params + B16 ports.
	//   else — clock/legacy store (PX_PER_CLK multi-pixel); B16 stats tied off.
	// Product BEAM_960 + B7/B16 requires w-mem store merge (do not whole-file drop).
`ifdef DDR_FRAME_STORE_RUNTIME_GEOM
	ddr_frame_store #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.FRAME_STRIDE(FRAME_STRIDE),
		.CODED_W(DDR_FRAME_CODED_WIDTH),
		.CODED_H(DDR_FRAME_CODED_HEIGHT),
		.DISPLAY_W(DDR_FRAME_DISPLAY_WIDTH),
		.DISPLAY_H(DDR_FRAME_DISPLAY_HEIGHT),
		.CROP_LEFT(DDR_FRAME_CROP_LEFT),
		.CROP_TOP(DDR_FRAME_CROP_TOP),
		.PRESENT_X(DDR_FRAME_PILLARBOX_LEFT),
		.PRESENT_Y(0),
		.LINE_COUNT(FRAME_LINE_COUNT),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(DDR_FRAME_YUV420P_BANK_STRIDE),
		.DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS),
		// B7 Option-C (capacity select + OPTION_C LEG re-base) — from w-mem 23451699
		.PHYS_BASE_720P(PC_PHYS_BASE_720P),
		.HPS_BANK_STRIDE_BYTES_720P(PC_STRIDE_720P),
		.DOORBELL_PHYS_720P(PC_DOORBELL_720P)
	) fstore (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(fstore_rd_x),
		.rd_y(fstore_rd_y),
		.rd_active(fstore_rd_a),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.geom_enable(geom_enable),
		.rt_geom_seq(geom_live_seq),
		.rt_geom_live(geom_live_valid),
		.rt_coded_w(geom_coded_w),
		.rt_coded_h(geom_coded_h),
		.rt_y_stride(geom_y_stride),
		.rt_chroma_stride(geom_chroma_stride),
		.rt_display_w(geom_display_w),
		.rt_display_h(geom_display_h),
		.rt_present_x(geom_present_x),
		.rt_present_y(geom_present_y),
		.rt_crop_left(geom_crop_left),
		.rt_crop_top(geom_crop_top),
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
`ifdef PRESENT_MULTI_PIXEL
		.vsync_pulse(mp_out_fs),
`else
		.vsync_pulse(fstart),
`endif
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(frame_underruns),
		.frames_done(ddr_frames_done),
		.doorbell_ok(ddr_doorbell_ok),
		.debug_state(frame_sdram_state),
		.pending_ready(store_pending_ready),
		.geom_hold_black(geom_hold_black),
		.geom_hollow_fault(geom_hollow_fault),
		.q5_reserved_reject(q5_reserved_reject)
	);
`else
	// Legacy/clock store (PX_PER_CLK). B7/B16 not on this pin list — tie stats.
	assign geom_hold_black = 1'b0;
	assign geom_hollow_fault = 1'b0;
	ddr_frame_store #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.FRAME_STRIDE(FRAME_STRIDE),
		.CODED_W(DDR_FRAME_CODED_WIDTH),
		.CODED_H(DDR_FRAME_CODED_HEIGHT),
		.DISPLAY_W(DDR_FRAME_DISPLAY_WIDTH),
		.DISPLAY_H(DDR_FRAME_DISPLAY_HEIGHT),
		.CROP_LEFT(DDR_FRAME_CROP_LEFT),
		.CROP_TOP(DDR_FRAME_CROP_TOP),
		.PRESENT_X(DDR_FRAME_PILLARBOX_LEFT),
		.PRESENT_Y(0),
		.LINE_COUNT(FRAME_LINE_COUNT),
		.PHYS_BASE(32'h3000_0000),
		.HPS_BANK_STRIDE_BYTES(DDR_FRAME_YUV420P_BANK_STRIDE),
		.DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS),
		.PX_PER_CLK(PRESENT_PPC)
	) fstore (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(fstore_rd_x),
		.rd_y(fstore_rd_y),
		.rd_active(fstore_rd_a),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.rd_r_n(fs_r_n),
		.rd_g_n(fs_g_n),
		.rd_b_n(fs_b_n),
		.rd_lane_valid_n(fs_lane_v_n),
		.rd_n_valid(fs_n_valid),
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
`ifdef PRESENT_MULTI_PIXEL
		.vsync_pulse(mp_out_fs),
`else
		.vsync_pulse(fstart),
`endif
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(frame_underruns),
		.frames_done(ddr_frames_done),
		.doorbell_ok(ddr_doorbell_ok),
		.debug_state(frame_sdram_state),
		.pending_ready(store_pending_ready)
	);
`endif // DDR_FRAME_STORE_RUNTIME_GEOM
`else // !DDR_FRAME_STORE
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
		.rd_x(store_x),
		.rd_y(store_y),
		// Full content DE (registered); hold inside frame_store across !ce_pix
		.rd_active(de_r),
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
		.vsync_pulse(fstart),
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(frame_underruns),
		.debug_state(frame_sdram_state)
	);
	// store_pending_ready tied 1 above when !DDR_FRAME_STORE (B20 free-run).
`endif

`ifdef PRESENT_MULTI_PIXEL
`ifdef DDR_FRAME_STORE
	// N-wide store RGB → wide-group npx FIFO → 1 px/clk.
	//
	// rd-duck integration fixes (quoted intent):
	// 1) Tag sync at *beam request*; delay MP_STORE_LAT sys clk to meet fs_n_valid.
	//    Sampling mp_hb_sam at response time skews line-edge RGB vs HS/DE.
	// 2) Every beam group → npx push after LAT: blank=black+sync; DE+fs=store RGB;
	//    DE without fs (no frame / miss)=black. No-frame still runs continuous raster.
	// 3) Mode-on H/V/ce always from mp path — never legacy hb_d while CLK_VIDEO=clk_pix.
	// 4) ddr vsync_pulse = mp_out_fs (FIFO-aligned fstart; not raw beam mp_fstart).
	// 5) FORBIDDEN: dual-latency OR (blank@1 | fs_n_valid@LAT). Same-cycle collision
	//    drops a raster group; blank can overtake trailing DE. All groups share one
	//    ordered pipe; mp_npx_valid = mp_push only (see RED_DUAL_OR TB).
	//
	// LAT: beam_ce→mp_de_r(1) + rd_active_r(1) + rd_active_d(1) + yuv(1) = 4.
	localparam int MP_STORE_LAT = 4;

	reg [MP_STORE_LAT-1:0]          mp_tq_v;
	reg                             mp_tq_hb [0:MP_STORE_LAT-1];
	reg                             mp_tq_hs [0:MP_STORE_LAT-1];
	reg                             mp_tq_vb [0:MP_STORE_LAT-1];
	reg                             mp_tq_vs [0:MP_STORE_LAT-1];
	reg                             mp_tq_fs [0:MP_STORE_LAT-1];
	reg [PRESENT_PPC-1:0]           mp_tq_lde [0:MP_STORE_LAT-1];
	integer                         mp_ti;

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
			// Shift toward [LAT-1]; load [0] on beam_ce, else bubble (v=0).
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

	wire                    mp_push     = mp_tq_v[MP_STORE_LAT-1];
	wire                    mp_push_hb  = mp_tq_hb[MP_STORE_LAT-1];
	wire                    mp_push_hs  = mp_tq_hs[MP_STORE_LAT-1];
	wire                    mp_push_vb  = mp_tq_vb[MP_STORE_LAT-1];
	wire                    mp_push_vs  = mp_tq_vs[MP_STORE_LAT-1];
	wire                    mp_push_fs  = mp_tq_fs[MP_STORE_LAT-1];
	wire [PRESENT_PPC-1:0]  mp_push_lde = mp_tq_lde[MP_STORE_LAT-1];
	wire                    mp_push_de  = |mp_push_lde;
	// Store RGB only when response aligns with a DE-tagged slot.
	wire                    mp_use_fs   = mp_push && mp_push_de && fs_n_valid;

	wire mp_npx_valid = mp_push;
	wire [PRESENT_PPC*8-1:0] mp_npx_r =
		mp_use_fs ? fs_r_n : {PRESENT_PPC{8'd0}};
	wire [PRESENT_PPC*8-1:0] mp_npx_g =
		mp_use_fs ? fs_g_n : {PRESENT_PPC{8'd0}};
	wire [PRESENT_PPC*8-1:0] mp_npx_b =
		mp_use_fs ? fs_b_n : {PRESENT_PPC{8'd0}};
	// Any push → all lanes valid black or store RGB (PPC-aligned product groups).
	wire [PRESENT_PPC-1:0] mp_npx_lane_q = mp_push ? {PRESENT_PPC{1'b1}} : {PRESENT_PPC{1'b0}};
	wire mp_npx_hb = mp_push_hb;
	wire mp_npx_hs = mp_push_hs;
	wire mp_npx_vb = mp_push_vb;
	wire mp_npx_vs = mp_push_vs;
	wire mp_npx_fs = mp_push_fs;

	// clk_pix reset: async assert / sync deassert (never raw `reset` in pix domain).
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

	present_npx_path #(
		.PX_PER_CLK(PRESENT_PPC),
		.FIFO_AW(6),
		.INCLUDE_SYNC(MP_INCLUDE_SYNC),
		.PREFILL_GROUPS(16)  // startup watermark (rd-duck long-haul)
	) u_mp_npx_path (
		.clk_sys(clk),
		.reset_sys(reset),
		.clk_pix(clk_pix),
		.reset_pix(mp_reset_pix),
		.in_valid(mp_npx_valid),
		.in_r(mp_npx_r),
		.in_g(mp_npx_g),
		.in_b(mp_npx_b),
		.in_lane_valid(mp_npx_lane_q),
		.in_hblank(mp_npx_hb),
		.in_hsync(mp_npx_hs),
		.in_vblank(mp_npx_vb),
		.in_vsync(mp_npx_vs),
		.in_fstart(mp_npx_fs),
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

	// --- Observable pix underrun (anti-DCE) — rd-duck 2e ---
	// Toggle CDC undercounts paired/back-to-back empty pixels (every other
	// pulse lost when two empties land before sys samples). Level-sync a
	// pix-domain sticky; Gray-code a free-running pix counter and accumulate
	// binary deltas on sys. PLXF bit15 = sticky, [14:0] = store+pix counts.
	function automatic [7:0] mp_ur_bin2gray8(input [7:0] b);
		mp_ur_bin2gray8 = b ^ (b >> 1);
	endfunction
	function automatic [7:0] mp_ur_gray2bin8(input [7:0] g);
		integer uk;
		begin
			mp_ur_gray2bin8[7] = g[7];
			for (uk = 6; uk >= 0; uk = uk - 1)
				mp_ur_gray2bin8[uk] = mp_ur_gray2bin8[uk+1] ^ g[uk];
		end
	endfunction

	(* noprune *) reg        mp_rd_ur_sticky_pix;
	(* noprune *) reg [7:0]  mp_rd_ur_bin_pix;
	(* noprune *) reg [7:0]  mp_rd_ur_gray_pix;
	(* noprune *) reg [2:0]  mp_rd_ur_sticky_sync;
	(* noprune *) reg [7:0]  mp_rd_ur_g0, mp_rd_ur_g1;
	(* noprune *) reg [7:0]  mp_rd_ur_bin_last;
	(* noprune *) reg        mp_rd_ur_sticky;
	(* noprune *) reg [14:0] mp_rd_ur_count;

	wire [7:0] mp_rd_ur_bin_now = mp_ur_gray2bin8(mp_rd_ur_g1);
	wire [7:0] mp_rd_ur_delta   = mp_rd_ur_bin_now - mp_rd_ur_bin_last;

	always @(posedge clk_pix) begin
		if (mp_reset_pix) begin
			mp_rd_ur_sticky_pix <= 1'b0;
			mp_rd_ur_bin_pix    <= 8'd0;
			mp_rd_ur_gray_pix   <= 8'd0;
		end else if (mp_rd_ur) begin
			mp_rd_ur_sticky_pix <= 1'b1;
			mp_rd_ur_bin_pix    <= mp_rd_ur_bin_pix + 8'd1;
			mp_rd_ur_gray_pix   <= mp_ur_bin2gray8(mp_rd_ur_bin_pix + 8'd1);
		end
	end

	always @(posedge clk) begin
		if (reset) begin
			mp_rd_ur_sticky_sync <= 3'b0;
			mp_rd_ur_g0          <= 8'd0;
			mp_rd_ur_g1          <= 8'd0;
			mp_rd_ur_bin_last    <= 8'd0;
			mp_rd_ur_sticky      <= 1'b0;
			mp_rd_ur_count       <= 15'd0;
		end else begin
			mp_rd_ur_sticky_sync <= {mp_rd_ur_sticky_sync[1:0], mp_rd_ur_sticky_pix};
			mp_rd_ur_g0          <= mp_rd_ur_gray_pix;
			mp_rd_ur_g1          <= mp_rd_ur_g0;
			mp_rd_ur_bin_last    <= mp_rd_ur_bin_now;
			// Sticky latches once (host-visible); level-sync so sustained empty
			// keeps the bit set without needing edges.
			if (mp_rd_ur_sticky_sync[2])
				mp_rd_ur_sticky <= 1'b1;
			// Saturate with 16-bit sum (rd-duck): 15-bit add wraps before compare
			// e.g. 15'h7ffe + 2 = 0 in 15 bits → falsely took non-sat path.
			if (mp_rd_ur_delta != 8'd0) begin
				if (16'({1'b0, mp_rd_ur_count}) + 16'(mp_rd_ur_delta) < 16'h7fff)
					mp_rd_ur_count <= mp_rd_ur_count + 15'(mp_rd_ur_delta);
				else
					mp_rd_ur_count <= 15'h7fff;
			end
		end
	end
	// Combine store underruns (low) with mp pix underrun count; bit15 = sticky.
	// MP_UR_STICKY — host PLXF bit15 anti-elision marker (rd-duck 2e).
	// Store underrun is 16-bit; status [14:0] is a 15-bit field with bit15=sticky.
	// Truncating frame_underruns[14:0] aliases 0x8000→0 (rd-duck). Saturate store
	// into 15 bits first, then saturating-add pix count.
	wire [14:0] mp_store_ur15 =
		(frame_underruns >= 16'h7fff) ? 15'h7fff : frame_underruns[14:0];
	wire [15:0] mp_ur_sum16 =
		{1'b0, mp_store_ur15} + {1'b0, mp_rd_ur_count};
	wire [14:0] mp_ur_sum =
		(mp_ur_sum16 >= 16'h7fff) ? 15'h7fff : mp_ur_sum16[14:0];
	wire [15:0] mp_stat_frame_underruns = {mp_rd_ur_sticky, mp_ur_sum};

	// FIFO sideband owns H/V/fstart always (same-clock and PLL).
	// rd-duck: direct mp_hb with INCLUDE_SYNC=0 left DE leading RGB by queue.
	wire mp_hb_d = mp_out_hb;
	wire mp_hs_d = mp_out_hs;
	wire mp_vb_d = mp_out_vb;
	wire mp_vs_d = mp_out_vs;
	// mp_out_fs drives frame_start + ddr vsync_pulse (FIFO-aligned).
	wire mp_de_out = ~mp_hb_d & ~mp_vb_d;
	wire mp_mode_ok = (mp_h_de == 12'd1280) && (mp_v_act == 12'd720)
		&& (mp_h_total == 12'd1650) && (mp_v_total == 12'd750);
	// Keep hierarchy roots referenced; underrun sticky is status-visible (not only here).
	wire _unused_mp_flags = mp_beam_ce | mp_wr_full | mp_wr_af | mp_rd_empty
		| (|mp_lane_de_r) | (|fs_lane_v_n) | (MP_STORE_LAT == 4)
		| mp_mode_ok | mp_needs_fast_pix | (|mp_fps_milli) | mp_identity_geom_ok
		| mp_use_fs | mp_rd_ur_sticky | (|mp_rd_ur_count) | mp_reset_pix;
`endif

	// Non-DDR path: no B16 store blackout.
	assign geom_hold_black = 1'b0;
	assign geom_hollow_fault = 1'b0;
`endif

	// Product: once a frame is ingested, always show frame_store unless O[9] Force bars.
	// Pattern no longer steals cast (old pattern!=0 force caused bars/grid under video).
	// Pattern=None (0) + no frame → black (nothing “runs” behind cast).
	wire use_ext = has_frame && !use_frame_store;
	wire show_pattern = !use_ext && (use_frame_store || (pattern != 2'd0));
	// B20: force core RGB black while candidate visual epoch != applied (and/or
	// store B16 hold). ascal HDMI_BLACKOUT is size-only; this covers fps/window
	// and DE/bank mismatch without relying on ascal iauto alone.
	wire visual_force_black = b20_visual_hold | geom_hold_black;
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
	// HDMI and reports where each landed. Sweeping 3..6 on hardware (RGB565
	// frame_store @ FRAME_W=320):
	//   3 -> col0 w=6px, col319 w=4px   (correct)
	//   4 -> col0 w=4px, col319 w=7px
	//   5 -> col0 MISSING, col319 w=11px
	//   6 -> col0 MISSING, col319 w=14px
	// Each extra clk of lag eats ~0.6 of a source column off the left and repeats it
	// on the right, which is precisely the right-edge "bar".
	//
	// REQUIRES_FIT (DDR_FRAME_STORE @ FRAME_W=640): DE_LAG has NOT been re-swept for
	// ddr_frame_store's deeper path (rd_visible pipeline + YUV + BRAM). A too-small
	// lag wraps previous-line right columns onto the left edge (ragged boundary +
	// left clip). Parent HDMI after ARM stride fix still saw ~44 px per-line left
	// wander — retune with gen_edge_markers.py on an authorised fit; do not guess
	// a new constant here without that sweep. Keep the frame_store-proven value
	// until then so we do not silently eat left columns.
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

`ifdef PRESENT_MULTI_PIXEL
`ifdef DDR_FRAME_STORE
	// Multi-pixel takeover for frame path. Pattern/bars still use colorbars.
	// ce_pix stays 1 (product scandouble class) so CLK_VIDEO pacing is stable.
	// During active DE: hold last serializer pixel across out_ce gaps (same-clock
	// backpressure). Black only in blank — never flash black mid-line on CE holes.
	// Outputs r/g/b/H*/V* are driven from this path whenever use_ext (runtime
	// has_frame) so Quartus cannot DCE the beam→store→npx chain as dead.
	// Hold on clk_pix (output domain). Reset must be pix-synced (mp_reset_pix),
	// never raw clk_sys `reset` sampled as data on clk_pix.
	reg [7:0] mp_r_hold, mp_g_hold, mp_b_hold;
	always @(posedge clk_pix) begin
		if (mp_reset_pix) begin
			mp_r_hold <= 8'd0;
			mp_g_hold <= 8'd0;
			mp_b_hold <= 8'd0;
		end else if (mp_out_ce) begin
			mp_r_hold <= mp_out_r;
			mp_g_hold <= mp_out_g;
			mp_b_hold <= mp_out_b;
		end else if (!mp_de_out) begin
			mp_r_hold <= 8'd0;
			mp_g_hold <= 8'd0;
			mp_b_hold <= 8'd0;
		end
	end
	wire [7:0] mp_r_px = mp_out_ce ? mp_out_r : mp_r_hold;
	wire [7:0] mp_g_px = mp_out_ce ? mp_out_g : mp_g_hold;
	wire [7:0] mp_b_px = mp_out_ce ? mp_out_b : mp_b_hold;
	// Mode-on (PRESENT_MULTI_PIXEL+DDR): mp path owns H/V always.
	// CLK_VIDEO may be clk_pix — never fall back to legacy hb_d/br (20 MHz state).
	// PLL mode: do NOT gate RGB on unsynchronised clk_sys has_frame/use_frame_store.
	// Npx path already pushes black on !has_frame / store miss; a second gate on
	// async status tears DE. Pass mp_* pixels straight out.
`ifdef PRESENT_CLK_PIX_PLL
	assign r = visual_force_black ? 8'd0 : (mp_de_out ? mp_r_px : 8'd0);
	assign g = visual_force_black ? 8'd0 : (mp_de_out ? mp_g_px : 8'd0);
	assign b = visual_force_black ? 8'd0 : (mp_de_out ? mp_b_px : 8'd0);
	assign ce_pix = 1'b1; // CLK_VIDEO==clk_pix; CE always
	assign HBlank = mp_hb_d;
	assign HSync  = mp_hs_d;
	assign VBlank = mp_vb_d;
	assign VSync  = mp_vs_d;
	assign frame_start = mp_out_fs;
`else
	assign r = visual_force_black ? 8'd0 :
		(use_ext ? (mp_de_out ? mp_r_px : 8'd0) : (show_pattern ? br : 8'd0));
	assign g = visual_force_black ? 8'd0 :
		(use_ext ? (mp_de_out ? mp_g_px : 8'd0) : (show_pattern ? bg : 8'd0));
	assign b = visual_force_black ? 8'd0 :
		(use_ext ? (mp_de_out ? mp_b_px : 8'd0) : (show_pattern ? bb : 8'd0));
	assign ce_pix = 1'b1;
	// Same-clock: still prefer mp timing when multi-pixel mode is on so DE matches beam.
	assign HBlank = mp_hb_d;
	assign HSync  = mp_hs_d;
	assign VBlank = mp_vb_d;
	assign VSync  = mp_vs_d;
	assign frame_start = mp_out_fs;
`endif
`else
	// Multi-pixel macro without DDR store: keep legacy 1ppc path.
	assign r = visual_force_black ? 8'd0 :
		(use_ext ? (de_out ? fr : 8'd0) : (show_pattern ? br : 8'd0));
	assign g = visual_force_black ? 8'd0 :
		(use_ext ? (de_out ? fg : 8'd0) : (show_pattern ? bg : 8'd0));
	assign b = visual_force_black ? 8'd0 :
		(use_ext ? (de_out ? fb : 8'd0) : (show_pattern ? bb : 8'd0));
	assign ce_pix = ce_pix_i;
	assign HBlank = hb_d;
	assign HSync  = hs_d;
	assign VBlank = vb_d;
	assign VSync  = vs_d;
	assign frame_start = fstart;
`endif
`else
	assign r = visual_force_black ? 8'd0 :
		(use_ext ? (de_out ? fr : 8'd0) : (show_pattern ? br : 8'd0));
	assign g = visual_force_black ? 8'd0 :
		(use_ext ? (de_out ? fg : 8'd0) : (show_pattern ? bg : 8'd0));
	assign b = visual_force_black ? 8'd0 :
		(use_ext ? (de_out ? fb : 8'd0) : (show_pattern ? bb : 8'd0));

	assign ce_pix = ce_pix_i;
	assign HBlank = hb_d;
	assign HSync  = hs_d;
	assign VBlank = vb_d;
	assign VSync  = vs_d;
	assign frame_start = fstart;
`endif

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
`ifdef PRESENT_MULTI_PIXEL
`ifdef DDR_FRAME_STORE
	// bit15 = mp_rd_ur_sticky; [14:0] = store underruns + mp pix underrun count
	assign stat_frame_underruns = mp_stat_frame_underruns;
`else
	assign stat_frame_underruns = frame_underruns;
`endif
`else
	assign stat_frame_underruns = frame_underruns;
`endif
	assign stat_frame_sdram_state = frame_sdram_state;
	// B16 store hold OR B20 visual epoch hold (candidate live_seq != applied).
	assign stat_geom_hold_black = geom_hold_black | b20_visual_hold;
	assign stat_geom_hollow     = geom_hollow_fault;
	wire _keep_b16_stats = stat_geom_hold_black | stat_geom_hollow | _keep_win_geom_ports
		| (|app_content_fps) | (|app_content_w) | (|app_content_h)
		| app_win_enable | (|app_live_seq) | app_live_valid | visual_force_black;

endmodule
