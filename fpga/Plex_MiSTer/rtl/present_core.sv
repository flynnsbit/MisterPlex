// Present core: color bars OR external frame_store, cadence, tone + audio FIFO.
// Display owns VSync; unique content advances only when present_cadence says so.

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
	input  wire        reset,

	input  wire        pal,
	input  wire        scandouble,
	input  wire [7:0]  content_fps,
	input  wire [7:0]  display_hz,
	input  wire [1:0]  pattern,
	input  wire        audio_en,        // OSD tone enable (when no FIFO audio)
	input  wire        use_frame_store, // OSD force bars when 1

	// Fabric content window (runtime). win_enable=0 → legacy full FRAME map.
	// When 1, NN-stretch content_w×content_h at (content_x0,content_y0) across DE.
	// 11-bit geometry is 720p-native (1280×720); host programs before ARM drops scale.
	input  wire        win_enable,
	input  wire [10:0] content_w,
	input  wire [10:0] content_h,
	input  wire [10:0] content_x0,
	input  wire [10:0] content_y0,
	// 0 → defaults (h=529 FBAR, v=480). 720p DE is a reg write, not a redesign.
	input  wire [10:0] win_h_de,
	input  wire [10:0] win_v_de,

	// Runtime DDR bank geometry (PLXW). geom_enable=0 → legacy CODED 624 path.
	// Sized for 1280×720 (y_stride bytes). Safe default = all zero / disable.
	input  wire        geom_enable,
	input  wire [10:0] geom_coded_w,
	input  wire [10:0] geom_coded_h,
	input  wire [11:0] geom_y_stride,
	input  wire [10:0] geom_chroma_stride,
	input  wire [10:0] geom_display_w,
	input  wire [10:0] geom_display_h,
	input  wire [10:0] geom_present_x,
	input  wire [10:0] geom_present_y,
	input  wire [10:0] geom_crop_left,
	input  wire [10:0] geom_crop_top,

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

	localparam int FRAME_X_W = $clog2(FRAME_W);
	localparam int FRAME_Y_W = $clog2(FRAME_H);

	// Stretch store content across Template DE (colorbars hc/vc).
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
	// ASCAL NEAR-TERM FIT (true content DE — NOT this Template path):
	// Core must emit DE extent == content (960×540 or 640×360), identity store
	// map, no pad inside DE. Island-in-529/1280 is the quarter-glass dead end.
	// Integrator gate: tests/unit/test_true_content_de_contract.sh
	// Contract doc: docs/product-4-3-scaler-decision.md § True 960×540 DE.
	//
	// Fabric content window (win_enable): when 1, SX/SY come from runtime
	// content_w/h instead of FRAME_* so ARM publishes native WxH (320…1280) and
	// fabric NN-stretches across DE — ARM scale path goes to zero, not "cheaper".
	// win_enable=0 is bit-compatible legacy. STORE_W=1280 sized for 720p (1 M10K/line).
	// Mapping lives in present_content_window (NN V1; ascal remains HDMI scaler).
	localparam H_DE = 10'd529;
	localparam bit NATIVE_V_1TO1 = (FRAME_H > 240);
	localparam int V_STORE_I = NATIVE_V_1TO1 ? FRAME_H : 240;
	localparam [9:0] V_STORE = 10'(V_STORE_I);
	// Legacy scale constants retained for source-lock tests + documentation.
	// Runtime path uses present_content_window registered scales.
	// store_x ≈ floor(hc * FRAME_W / 529); 39647/65536 ≈ 320/529.
	localparam int STORE_X_SCALE = (FRAME_W * 39647) / 320;
	localparam int STORE_Y_SCALE = (FRAME_H * 65536) / V_STORE_I;
	// Beam Y for content + store. Native 480: use full vc (scandouble active 0..479).
	// Legacy 240: half when scandoubled so two display lines share one store row.
	wire [9:0] py = NATIVE_V_1TO1 ? vc : (scandouble ? (vc >> 1) : vc);
	wire in_content = (hc < H_DE) && (py < V_STORE) && ~hb && ~vb;

	// Drive store_x from free-running hc (no blank-time force-to-0). Blank-time
	// reset handed column 0 to DE_LAG-delayed right-edge pixels (1 px wrap).
	// Identity hc→read_hc kept at this layer for source-lock + DE_LAG docs;
	// present_content_window also treats hc as free-running (no blank force-0).
	wire [9:0] read_hc = hc;
	// Window emits full store coords (STORE 1280×720). ddr_frame_store rd_x/y
	// accept max(FRAME, MAX_CODED); legacy SDRAM frame_store still gets FRAME slice.
	localparam int STORE_W_MAX = 1280;
	localparam int STORE_H_MAX = 720;
	localparam int WIN_X_W = $clog2(STORE_W_MAX);
	localparam int WIN_Y_W = $clog2(STORE_H_MAX);
	wire [WIN_X_W-1:0] store_x_win;
	wire [WIN_Y_W-1:0] store_y_win;
	wire                 de_r; // registered in_content for frame_store read align
	wire                 past_last_row;

	present_content_window #(
		.FRAME_W(FRAME_W),
		.FRAME_H(FRAME_H),
		.STORE_W(STORE_W_MAX),
		.STORE_H(STORE_H_MAX),
		.H_DE_DEFAULT(529),
		.V_DE_DEFAULT(V_STORE_I)
	) content_win (
		.clk(clk),
		.reset(reset),
		.ce_pix(ce_pix_i),
		.hc({1'b0, read_hc}),
		.py({1'b0, py}),
		.in_content(in_content),
		.win_enable(win_enable),
		.content_w(content_w),
		.content_h(content_h),
		.content_x0(content_x0),
		.content_y0(content_y0),
		.h_de(win_h_de),
		.v_de(win_v_de),
		.store_x(store_x_win),
		.store_y(store_y_win),
		.de_r(de_r),
		.past_last_row(past_last_row)
	);

	// Full-width for DDR path (runtime geom / content window up to 1280×720).
	wire [WIN_X_W-1:0] store_x_full = store_x_win;
	wire [WIN_Y_W-1:0] store_y_full = store_y_win;
	// FRAME-sliced for legacy SDRAM frame_store ports.
	wire [FRAME_X_W-1:0] store_x = store_x_win[FRAME_X_W-1:0];
	wire [FRAME_Y_W-1:0] store_y = store_y_win[FRAME_Y_W-1:0];

	// Keep legacy scale localparams live for elab/source-lock (child has its own).
	(* keep = 1 *) wire [31:0] _keep_legacy_store_scale =
		32'(STORE_X_SCALE) ^ {16'd0, 16'(STORE_Y_SCALE)};

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
		.DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)
	) fstore (
		.clk(clk),
		.clk_ddr(clk_ddr),
		.reset(reset),
		.rd_x(store_x_full),
		.rd_y(store_y_full),
		.rd_active(de_r),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.geom_enable(geom_enable),
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
		.vsync_pulse(fstart),
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
	assign r = use_ext ? (de_out ? fr : 8'd0) : (show_pattern ? br : 8'd0);
	assign g = use_ext ? (de_out ? fg : 8'd0) : (show_pattern ? bg : 8'd0);
	assign b = use_ext ? (de_out ? fb : 8'd0) : (show_pattern ? bb : 8'd0);

	assign ce_pix = ce_pix_i;
	assign HBlank = hb_d;
	assign HSync  = hs_d;
	assign VBlank = vb_d;
	assign VSync  = vs_d;
	assign frame_start = fstart;

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
