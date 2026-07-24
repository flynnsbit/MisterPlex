// Phase-1 present core: color bars + cadence + tone wiring helpers.
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

	// status for future HPS readout
	output wire [31:0] stat_display_index,
	output wire [31:0] stat_content_index,
	output wire        stat_advance
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

	colorbars bars (
		.clk(clk),
		.reset(reset),
		.pal(pal),
		.scandouble(scandouble),
		.content_index(cont_i),
		.pattern(pattern),
		.ce_pix(ce_pix),
		.HBlank(HBlank),
		.HSync(HSync),
		.VBlank(VBlank),
		.VSync(VSync),
		.frame_start(frame_start),
		.r(r),
		.g(g),
		.b(b)
	);

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

endmodule
