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
	// Combinational mul+shift (no lpm_divide), registered on ce_pix for timing.
	wire [25:0] store_x_prod = hc * 16'd39647;
	wire [9:0]  store_x_comb = store_x_prod[25:16];
	wire [9:0]  store_x_clamped =
		(store_x_comb >= H_STORE) ? (H_STORE - 10'd1) : store_x_comb;

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
			store_y <= py;
			store_x <= in_content ? store_x_clamped : 10'd0;
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
	// Registered DE hold for ext path: colorbars holds on !ce_pix; fr holds too.
	reg use_ext_de;
	always @(posedge clk) begin
		if (reset)
			use_ext_de <= 1'b0;
		else if (ce_pix_i)
			use_ext_de <= use_ext && in_content;
	end
	assign r = use_ext ? (use_ext_de ? fr : 8'd0) : (show_pattern ? br : 8'd0);
	assign g = use_ext ? (use_ext_de ? fg : 8'd0) : (show_pattern ? bg : 8'd0);
	assign b = use_ext ? (use_ext_de ? fb : 8'd0) : (show_pattern ? bb : 8'd0);

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
