// Present core: color bars OR external frame_store, with cadence + tone.
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
	input  wire        audio_en,
	input  wire        use_frame_store, // 1 = external RGB frames when has_frame

	// frame_store write (from ingest)
	input  wire        fs_wr_en,
	input  wire [15:0] fs_wr_pixel,
	input  wire        fs_wr_reset,
	input  wire        fs_swap,

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
	output wire [18:0] stat_wr_count
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

	colorbars bars (
		.clk(clk),
		.reset(reset),
		.pal(pal),
		.scandouble(scandouble),
		.content_index(cont_i),
		.pattern(pattern),
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

	// Reconstruct hc/vc from colorbars timing for frame_store reads.
	// colorbars uses 320 active; track counters in parallel for external sample.
	reg [9:0] hc, vc;
	reg       ce_div;
	always @(posedge clk) begin
		if (reset) begin
			hc <= 0;
			vc <= 0;
			ce_div <= 0;
		end else begin
			ce_div <= ~ce_div;
			if (ce_pix_i) begin
				if (hc == 10'd425) begin
					hc <= 0;
					if (vc >= (scandouble ? 10'd523 : 10'd261))
						vc <= 0;
					else
						vc <= vc + 1'd1;
				end else
					hc <= hc + 1'd1;
			end
		end
	end

	wire active = (hc < 10'd320) && (vc < (scandouble ? 10'd480 : 10'd240));
	// When scandoubled, map y/2 for 240-line store
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

	// Mux: external frame when enabled and ready, else bars
	wire use_ext = use_frame_store && has_frame;
	assign r = use_ext ? fr : br;
	assign g = use_ext ? fg : bg;
	assign b = use_ext ? fb : bb;

	assign ce_pix = ce_pix_i;
	assign HBlank = hb;
	assign HSync  = hs;
	assign VBlank = vb;
	assign VSync  = vs;
	assign frame_start = fstart;

	audio_tone tone (
		.clk_audio(clk_audio),
		.reset(reset),
		.enable(audio_en),
		.freq_div(16'd54),
		.sample_l(audio_l),
		.sample_r(audio_r),
		.underrun()
	);

	assign stat_display_index = disp_i;
	assign stat_content_index = cont_i;
	assign stat_advance       = advance;
	assign stat_has_frame     = has_frame;
	assign stat_wr_count      = wr_count;

endmodule
