// Present core: color bars OR external frame_store, cadence, tone + audio FIFO.
// Display owns VSync; unique content advances only when present_cadence says so.
//
// Multi-pixel present (720p path): see .agent-work/w-clock/MULTI_PIXEL_PRESENT_DESIGN.md
// and assets/multi_pixel_present_contract.json. Product default is 1 px/clk.
// `define PRESENT_MULTI_PIXEL  — connect beam → ddr N-wide → present_npx_path → RGB/CE
// `define PRESENT_PX_PER_CLK N — 1|2|4 (only meaningful with PRESENT_MULTI_PIXEL)
// `define PRESENT_CLK_PIX_PLL — separate clk_pix (outclk_3); rate-match + sync sideband
// Neither macro is defined in shipping / default fits (default-safe).
// Parent enables in an integration fit grant — do not define in QSF without grant.

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
`ifdef PRESENT_MULTI_PIXEL
	localparam int PRESENT_PPC = `PRESENT_PX_PER_CLK;
`else
	localparam int PRESENT_PPC = 1;
`endif

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

	// Product core timing is always 480 active lines (VBlank @ vc==480).
	// forced_scandoubler/cfg[4] must NOT select a 240-line progressive DE: on
	// 78eff44e that left V_STORE_PROG=240 + store_y=py*2 (even rows only) and
	// parent scored P5=MISS (period 3.988 ≈ 240-row pred 3.983). Hard-wire the
	// colorbars 480-line arm; the scandouble port is retained for hierarchy but
	// does not gate store height or DE line count.
	localparam bit PRODUCT_V_480 = 1'b1;
	wire _unused_scandouble_port = scandouble;

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

	localparam int FRAME_X_W = $clog2(FRAME_W);
	localparam int FRAME_Y_W = $clog2(FRAME_H);

	// Stretch FRAME_W×FRAME_H frame_store across full Template DE — match colorbars in_content.
	// Prior attempts (combo ÷529, reconstructed hc Bresenham) still UVC-pillar 0.604 on
	// solid-red F1 while bars on same RBF span 0.998. Use colorbars hc + mul-shift.
	//
	// T7b (post P5=MISS on 78eff44e): product always fetches FRAME_H unique store
	// rows 1:1. Defect was the PROG arm: V_STORE_PROG=240 + STORE_Y_SCALE=2.0 ⇒
	// store_y = py*2 over 240 DE lines ⇒ even rows only. Fix BOTH sides:
	//   (1) colorbars DE = 480 via PRODUCT_V_480 (above)
	//   (2) v_store = FRAME_H, STORE_Y_SCALE = 1.0 Q16 — NO scandouble mux, NO *2
	// THE LINE THAT STOPS DOUBLING: store_y_scale is constant 65536 (1.0), not
	// the old scandouble ? 1.0 : 2.0 mux. store_y_addr = py (clamped), not py*2.
	// Horizontal H_DE=529 Template DE unchanged (FBAR/DE_LAG class); 529-of-640 X deferred.
	// Native 720p multi-pixel beam (H_DE=1280, +N step) lives in present_beam_ppc.sv and
	// is NOT selected here unless PRESENT_MULTI_PIXEL is defined (defaults OFF).
	localparam H_DE    = 10'd529;
	localparam int V_STORE = FRAME_H; // product: full store height (480), both arms
	localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
	// 1.0 Q16 always — progressive must not double. (FRAME_H*65536)/V_STORE = 65536.
	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE;
	localparam [FRAME_X_W-1:0] FRAME_LAST_X = FRAME_X_W'(FRAME_W - 1);
	localparam [FRAME_Y_W-1:0] FRAME_LAST_Y = FRAME_Y_W'(FRAME_H - 1);
	localparam [15:0] FRAME_LAST_X_16 = 16'(FRAME_W - 1);
	localparam [15:0] FRAME_LAST_Y_16 = 16'(FRAME_H - 1);

	// Store beam Y: physical line index 0..FRAME_H-1. Never vc>>1, never *2.
	wire [9:0] py = vc;
	wire [9:0] v_store = 10'(V_STORE);
	wire in_content = (hc < H_DE) && (py < v_store) && ~hb && ~vb;
	// store_x = floor(hc * FRAME_W / 529) via (hc * STORE_X_SCALE) >> 16
	// Drive the address straight from the clamped counter, with no blank-time special
	// case. Forcing store_x to 0 during blank used to hand column 0 to any display
	// pixel whose address was issued outside `in_content` — with the sync delayed by
	// DE_LAG that includes the last pixels of every line, which is what wrapped the
	// first column onto the RIGHT edge. Free-running, hc keeps counting past H_DE so
	// the clamp naturally holds column LAST through the right overhang, and hc wraps to
	// 0 early in the left blank so column 0 is ready before DE opens.
	wire [9:0] read_hc = hc;
	wire [31:0] store_x_prod = read_hc * STORE_X_SCALE;
	wire [15:0] store_x_comb = store_x_prod[31:16];
	wire [FRAME_X_W-1:0] store_x_clamped =
		(store_x_comb > FRAME_LAST_X_16) ? FRAME_LAST_X : store_x_comb[FRAME_X_W-1:0];

	// Clamp Y to the active store window; scale always 1:1 (no PROG *2).
	wire       past_last_row = (py >= v_store);
	wire [9:0] store_y_clamped = past_last_row ? (v_store - 10'd1) : py;
	// *** T7b: constant 1.0 Q16 — this assignment is what stops store_y doubling ***
	wire [31:0] store_y_scale = 32'(STORE_Y_SCALE);
	wire [31:0] store_y_prod = store_y_clamped * store_y_scale;
	wire [15:0] store_y_comb = store_y_prod[31:16];
	wire [FRAME_Y_W-1:0] store_y_addr =
		(store_y_comb > FRAME_LAST_Y_16) ? FRAME_LAST_Y : store_y_comb[FRAME_Y_W-1:0];
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
	wire                mp_out_hb, mp_out_hs, mp_out_vb, mp_out_vs;
	wire                mp_wr_full, mp_wr_af, mp_rd_ur, mp_rd_empty;

`ifdef PRESENT_CLK_PIX_PLL
`ifdef PRESENT_CLK_PIX_30
	// PIX30 glass content rate (not held fit). Requires PRESENT_CLK_PIX_PLL.
	localparam int MP_CLK_PIX_HZ = 37_125_000;
`else
	localparam int MP_CLK_PIX_HZ = 29_700_000; // PIX24 held fit
`endif
	localparam bit MP_INCLUDE_SYNC = 1'b1;
`else
	localparam int MP_CLK_PIX_HZ = 20_000_000;
	localparam bit MP_INCLUDE_SYNC = 1'b0;
`endif

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
		// Bank swap on multi-pixel beam frame boundary — not legacy colorbars fstart.
		.vsync_pulse(mp_fstart),
`else
		.vsync_pulse(fstart),
`endif
		.has_frame(has_frame),
		.swap_pending(swap_pending),
		.underrun_count(frame_underruns),
		.frames_done(ddr_frames_done),
		.doorbell_ok(ddr_doorbell_ok),
		.debug_state(frame_sdram_state)
	);
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
	// 4) ddr vsync_pulse = mp_fstart (bank swap on 720 beam, not colorbars fstart).
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
				mp_tq_lde[mp_ti] <= mp_tq_lde[mp_ti-1];
			end
			mp_tq_v[0]   <= mp_beam_ce;
			mp_tq_hb[0]  <= mp_beam_ce ? mp_hb : 1'b1;
			mp_tq_hs[0]  <= mp_beam_ce ? mp_hs : 1'b0;
			mp_tq_vb[0]  <= mp_beam_ce ? mp_vb : 1'b1;
			mp_tq_vs[0]  <= mp_beam_ce ? mp_vs : 1'b0;
			mp_tq_lde[0] <= mp_beam_ce ? mp_lane_de : '0;
		end
	end

	wire                    mp_push     = mp_tq_v[MP_STORE_LAT-1];
	wire                    mp_push_hb  = mp_tq_hb[MP_STORE_LAT-1];
	wire                    mp_push_hs  = mp_tq_hs[MP_STORE_LAT-1];
	wire                    mp_push_vb  = mp_tq_vb[MP_STORE_LAT-1];
	wire                    mp_push_vs  = mp_tq_vs[MP_STORE_LAT-1];
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
		.in_ready(mp_in_ready),
		.out_ce(mp_out_ce),
		.out_r(mp_out_r),
		.out_g(mp_out_g),
		.out_b(mp_out_b),
		.out_hblank(mp_out_hb),
		.out_hsync(mp_out_hs),
		.out_vblank(mp_out_vb),
		.out_vsync(mp_out_vs),
		.wr_full(mp_wr_full),
		.wr_almost_full(mp_wr_af),
		.rd_underrun(mp_rd_ur),
		.rd_empty(mp_rd_empty)
	);

	// --- Observable pix underrun (anti-DCE): sticky + count into stat_frame_underruns
	// mp_rd_ur is clk_pix; toggle-sync to clk, then sticky/count on sys.
	// status bit15 of stat_frame_underruns = mp_rd_ur_sticky (MP_UR_STICKY marker).
	(* noprune *) reg        mp_rd_ur_toggle_pix;
	(* noprune *) reg [2:0]  mp_rd_ur_sync_sys;
	(* noprune *) reg        mp_rd_ur_sticky;
	(* noprune *) reg [14:0] mp_rd_ur_count;
	always @(posedge clk_pix or posedge mp_reset_pix) begin
		if (mp_reset_pix)
			mp_rd_ur_toggle_pix <= 1'b0;
		else if (mp_rd_ur)
			mp_rd_ur_toggle_pix <= ~mp_rd_ur_toggle_pix;
	end
	wire mp_rd_ur_sys_pulse = mp_rd_ur_sync_sys[2] ^ mp_rd_ur_sync_sys[1];
	always @(posedge clk) begin
		if (reset) begin
			mp_rd_ur_sync_sys <= 3'b0;
			mp_rd_ur_sticky   <= 1'b0;
			mp_rd_ur_count    <= 15'd0;
		end else begin
			mp_rd_ur_sync_sys <= {mp_rd_ur_sync_sys[1:0], mp_rd_ur_toggle_pix};
			if (mp_rd_ur_sys_pulse) begin
				mp_rd_ur_sticky <= 1'b1;
				if (mp_rd_ur_count != 15'h7fff)
					mp_rd_ur_count <= mp_rd_ur_count + 15'd1;
			end
		end
	end
	// Combine store underruns (low) with mp pix underrun sticky (bit15).
	wire [14:0] mp_ur_sum =
		(frame_underruns[14:0] > (15'h7fff - mp_rd_ur_count))
			? 15'h7fff
			: (frame_underruns[14:0] + mp_rd_ur_count);
	wire [15:0] mp_stat_frame_underruns = {mp_rd_ur_sticky, mp_ur_sum};

	// Dual-clock: FIFO sideband owns H/V. Same-clock: beam direct (low LAT).
`ifdef PRESENT_CLK_PIX_PLL
	wire mp_hb_d = mp_out_hb;
	wire mp_hs_d = mp_out_hs;
	wire mp_vb_d = mp_out_vb;
	wire mp_vs_d = mp_out_vs;
`else
	wire mp_hb_d = mp_hb;
	wire mp_hs_d = mp_hs;
	wire mp_vb_d = mp_vb;
	wire mp_vs_d = mp_vs;
`endif
	wire mp_de_out = ~mp_hb_d & ~mp_vb_d;
	wire mp_mode_ok = (mp_h_de == 12'd1280) && (mp_v_act == 12'd720)
		&& (mp_h_total == 12'd1650) && (mp_v_total == 12'd750);
	// Keep hierarchy roots referenced; underrun sticky is status-visible (not only here).
	wire _unused_mp_flags = mp_beam_ce | mp_wr_full | mp_wr_af | mp_rd_empty
		| (|mp_lane_de_r) | (|fs_lane_v_n) | (MP_STORE_LAT == 4)
		| mp_mode_ok | mp_needs_fast_pix | (|mp_fps_milli) | mp_identity_geom_ok
		| mp_use_fs | mp_rd_ur_sticky | (|mp_rd_ur_count) | mp_reset_pix;
`endif
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
	// Hold on clk_pix (output domain) — was clk; dual-clock safe.
	reg [7:0] mp_r_hold, mp_g_hold, mp_b_hold;
	always @(posedge clk_pix) begin
		if (reset) begin
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
	// RGB: frame pixels when has_frame & !force-bars; else black (continuous raster).
	// Force-bars (use_frame_store) still allowed only on same-clock builds.
`ifdef PRESENT_CLK_PIX_PLL
	assign r = mp_de_out ? ((has_frame && !use_frame_store) ? mp_r_px : 8'd0) : 8'd0;
	assign g = mp_de_out ? ((has_frame && !use_frame_store) ? mp_g_px : 8'd0) : 8'd0;
	assign b = mp_de_out ? ((has_frame && !use_frame_store) ? mp_b_px : 8'd0) : 8'd0;
	assign ce_pix = 1'b1; // CLK_VIDEO==clk_pix; CE always
	assign HBlank = mp_hb_d;
	assign HSync  = mp_hs_d;
	assign VBlank = mp_vb_d;
	assign VSync  = mp_vs_d;
	assign frame_start = mp_fstart;
`else
	assign r = use_ext ? (mp_de_out ? mp_r_px : 8'd0) : (show_pattern ? br : 8'd0);
	assign g = use_ext ? (mp_de_out ? mp_g_px : 8'd0) : (show_pattern ? bg : 8'd0);
	assign b = use_ext ? (mp_de_out ? mp_b_px : 8'd0) : (show_pattern ? bb : 8'd0);
	assign ce_pix = 1'b1;
	// Same-clock: still prefer mp timing when multi-pixel mode is on so DE matches beam.
	assign HBlank = mp_hb_d;
	assign HSync  = mp_hs_d;
	assign VBlank = mp_vb_d;
	assign VSync  = mp_vs_d;
	assign frame_start = mp_fstart;
`endif
`else
	// Multi-pixel macro without DDR store: keep legacy 1ppc path.
	assign r = use_ext ? (de_out ? fr : 8'd0) : (show_pattern ? br : 8'd0);
	assign g = use_ext ? (de_out ? fg : 8'd0) : (show_pattern ? bg : 8'd0);
	assign b = use_ext ? (de_out ? fb : 8'd0) : (show_pattern ? bb : 8'd0);
	assign ce_pix = ce_pix_i;
	assign HBlank = hb_d;
	assign HSync  = hs_d;
	assign VBlank = vb_d;
	assign VSync  = vs_d;
	assign frame_start = fstart;
`endif
`else
	assign r = use_ext ? (de_out ? fr : 8'd0) : (show_pattern ? br : 8'd0);
	assign g = use_ext ? (de_out ? fg : 8'd0) : (show_pattern ? bg : 8'd0);
	assign b = use_ext ? (de_out ? fb : 8'd0) : (show_pattern ? bb : 8'd0);

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

endmodule
