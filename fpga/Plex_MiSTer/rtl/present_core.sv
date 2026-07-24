// Present core: color bars OR external frame_store, cadence, tone + audio FIFO.
// Display owns VSync; unique content advances only when present_cadence says so.

module present_core (
	input  wire        clk,
	input  wire        clk_audio,
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
	output wire [18:0] stat_wr_count,
	output wire        stat_has_audio,
	output wire        stat_audio_underrun
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

	// OSD O[9] Force bars=Yes must show true color bars regardless of Pattern.
	// Without this override, force_bars only blocked frame_store while pattern
	// (grid/ramp/block) still drove colorbars — matrix saw identical frames.
	wire [1:0] eff_pattern = use_frame_store ? 2'd0 : pattern;

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
		.r(br),
		.g(bg),
		.b(bb)
	);

	// Reconstruct hc/vc from colorbars (Template) timing for frame_store reads.
	// Must match colorbars: hc 0..637 (638 clocks/line), not the old 426-line total.
	reg [9:0] hc, vc;
	always @(posedge clk) begin
		if (reset) begin
			hc <= 0;
			vc <= 0;
		end else if (ce_pix_i) begin
			if (hc == 10'd637) begin
				hc <= 0;
				if (vc >= (pal ? (scandouble ? 10'd623 : 10'd311)
				               : (scandouble ? 10'd523 : 10'd261)))
					vc <= 0;
				else
					vc <= vc + 1'd1;
			end else
				hc <= hc + 1'd1;
		end
	end

	// 320×240 content window inside Template-wide active (HBlank @ 529)
	wire active = (hc < 10'd320) && (vc < (scandouble ? 10'd480 : 10'd240));
	wire [9:0] store_y = scandouble ? {1'b0, vc[9:1]} : vc;
	wire [9:0] store_x = hc;

	wire [7:0] fr, fg, fb;
	wire       has_frame;
	wire [18:0] wr_count;
	wire        wr_done;

	frame_store #(
		.WIDTH(320),
		.HEIGHT(240)
	) fstore (
		.clk(clk),
		.reset(reset),
		.wr_en(fs_wr_en),
		.wr_pixel(fs_wr_pixel),
		.wr_reset_ptr(fs_wr_reset),
		.wr_count(wr_count),
		.wr_frame_done(wr_done),
		.rd_x(store_x),
		.rd_y(store_y),
		.rd_active(active && ce_pix_i),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		.swap_banks(fs_swap),
		.has_frame(has_frame)
	);

	// Auto: show frame_store once a complete frame is ingested.
	// use_frame_store (OSD O[9] Force bars=Yes): force color bars (eff_pattern=0)
	// and never take frame_store.
	// Non-default Pattern (Bars+Block/Grid/Ramp) also forces the pattern-gen path
	// so OSD Pattern is always visible even after has_frame latches.
	wire force_bars = use_frame_store | (pattern != 2'd0);
	wire use_ext = has_frame && !force_bars;
	assign r = use_ext ? fr : br;
	assign g = use_ext ? fg : bg;
	assign b = use_ext ? fb : bb;

	assign ce_pix = ce_pix_i;
	assign HBlank = hb;
	assign HSync  = hs;
	assign VBlank = vb;
	assign VSync  = vs;
	assign frame_start = fstart;

	// --- Audio: FIFO preferred, else OSD tone ---
	wire [15:0] tone_l, tone_r;
	wire [15:0] fifo_l, fifo_r;
	wire        has_audio;
	wire        fifo_underrun;

	audio_tone tone (
		.clk_audio(clk_audio),
		.reset(reset),
		.enable(audio_en && !has_audio),
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

endmodule
