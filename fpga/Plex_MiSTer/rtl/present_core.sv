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
	output wire        stat_audio_underrun,
	output wire        stat_swap_pending
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

	// Stretch 320×240 frame_store across full Template DE — match colorbars in_content.
	// Prior attempts (combo ÷529, reconstructed hc Bresenham) still UVC-pillar 0.604 on
	// solid-red F1 while bars on same RBF span 0.998. Use colorbars hc + mul-shift.
	localparam H_DE    = 10'd529;
	localparam H_STORE = 10'd320;
	// Exact clone of colorbars in_content (full DE paint region).
	wire [9:0] py = scandouble ? (vc >> 1) : vc;
	wire in_content = (hc < H_DE) && (py < 10'd240) && ~hb && ~vb;

	// store_x = floor(hc * 320 / 529) ≈ (hc * 39647) >> 16  (39647/65536 ≈ 0.6049)
	// Drive the address straight from the clamped counter, with no blank-time special
	// case. Forcing store_x to 0 during blank used to hand column 0 to any display
	// pixel whose address was issued outside `in_content` — with the sync delayed by
	// DE_LAG that includes the last pixels of every line, which is what wrapped the
	// first column onto the RIGHT edge. Free-running, hc keeps counting past H_DE so
	// the clamp naturally holds column 319 through the right overhang, and hc wraps to
	// 0 early in the left blank so column 0 is ready before DE opens.
	wire [9:0] read_hc = hc;
	wire [25:0] store_x_prod = read_hc * 16'd39647;
	wire [9:0]  store_x_comb = store_x_prod[25:16];
	wire [9:0]  store_x_clamped =
		(store_x_comb >= H_STORE) ? (H_STORE - 10'd1) : store_x_comb;

	// colorbars moves the V blank edges at hc == H_SYNC_S, i.e. AFTER each line's
	// active region, so VBlank releases a line early with respect to the content
	// window and line 240 is still displayed -- 241 active rows instead of 240.
	// Measured on hardware with scripts/gen_edge_markers.py's stripe pattern: the
	// bottom stripes land on a 1080/241 = 4.4813 row pitch, not 1080/240 = 4.5.
	// That surplus row is the "bottom line": nothing gates it on py, so it reads
	// store_y = 240, one row past the end of the 240-row store.
	// Blank it, and clamp the address so an out-of-range row can never be fetched.
	wire       past_last_row = (py >= 10'd240);
	wire [9:0] store_y_clamped = past_last_row ? 10'd239 : py;

	reg [9:0] store_x;
	reg [9:0] store_y;
	reg       de_r; // registered in_content for frame_store read align
	always @(posedge clk) begin
		if (reset) begin
			store_x <= 10'd0;
			store_y <= 10'd0;
			de_r    <= 1'b0;
		end else if (ce_pix_i) begin
			de_r    <= in_content;
			store_y <= store_y_clamped;
			store_x <= store_x_clamped;
		end
	end

	wire [7:0] fr, fg, fb;
	wire       has_frame;
	wire       swap_pending;
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
		// Full content DE (registered); hold inside frame_store across !ce_pix
		.rd_active(de_r),
		.rd_r(fr),
		.rd_g(fg),
		.rd_b(fb),
		// Request on DMA/F1 complete; apply only at display frame_start (vsync)
		.swap_banks(fs_swap),
		.vsync_pulse(fstart),
		.has_frame(has_frame),
		.swap_pending(swap_pending)
	);

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

endmodule
