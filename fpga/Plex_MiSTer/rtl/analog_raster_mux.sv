// Runtime analog raster mux for the SD-family product RBF.
// clk_sys = 20 MHz. Integer CE only — no HDMI / ascal modeline.
//
// sel 0 = 240p progressive 15 kHz class (Template colorbars, scandouble=0)
//   ce_pix toggle → 10 MHz, H_TOTAL=638 → 20e6/1276 = 15.674 kHz
// sel 1 = 480p scandouble ~31 kHz class
//   ce_pix=1 → 20 MHz, H_TOTAL=638 → 20e6/638 = 31.348 kHz
// sel 2 = 480i 15 kHz class + VGA_F1 field toggle (same H as 240p)
//
// ce_pix is a clk_sys clock-enable (colorbars), not a generated clock.
// STA: fpga/Plex_MiSTer/Plex_analog_mux.sdc — do not create_generated_clock
// on ce_pix / analog HSync. 15.6 kHz is H-rate; Fmax stays clk_sys 20 MHz.
//
// analog_sel / OSD O[15:14] / future HPS doorbell: reset-latch only.
// sel_lat does not follow live F12. field_odd still toggles on frame_start.
//
// HDMI LCD must never take a 15 kHz ascal video_mode from this module.
// Analog VGA_F1 is the 480i field flag; VGA_SCALER stays 0 at the parent.

module analog_raster_mux (
	input  wire        clk,
	input  wire        reset,
	input  wire        pal,
	input  wire [1:0]  raster_sel,    // 0=240p15, 1=480p31, 2=480i
	input  wire [31:0] content_index,
	input  wire [1:0]  pattern,

	output wire        ce_pix,
	output wire        HBlank,
	output wire        HSync,
	output wire        VBlank,
	output wire        VSync,
	output wire        frame_start,
	output reg         field_odd,
	output wire        scandouble_act,
	output wire [9:0]  hc_out,
	output wire [9:0]  vc_out,
	output wire [7:0]  r,
	output wire [7:0]  g,
	output wire [7:0]  b
);
	wire [1:0] sel_req = raster_sel;
`ifdef ANALOG_RASTER_FAULT_SWAP_SEL
	// RED twin: swap 240p/480p CE and suppress 480i field.
	wire [1:0] sel_eff = (sel_req == 2'd0) ? 2'd1 :
	                     (sel_req == 2'd1) ? 2'd0 : sel_req;
	localparam FAULT_NO_FIELD = 1'b1;
`else
	wire [1:0] sel_eff = sel_req;
	localparam FAULT_NO_FIELD = 1'b0;
`endif

	reg [1:0] sel_lat;
	assign scandouble_act = (sel_lat == 2'd1);

	wire fstart;
	colorbars bars (
		.clk(clk),
		.reset(reset),
		.pal(pal),
		.scandouble(scandouble_act),
		.content_index(content_index),
		.pattern(pattern),
		.ce_pix(ce_pix),
		.HBlank(HBlank),
		.HSync(HSync),
		.VBlank(VBlank),
		.VSync(VSync),
		.frame_start(fstart),
		.hc_out(hc_out),
		.vc_out(vc_out),
		.r(r),
		.g(g),
		.b(b)
	);
	assign frame_start = fstart;

	// sel_lat is reset-only (Plex_analog_mux.sdc). analog_sel is a run-constant;
	// live OSD O[15:14] / future doorbell must not retune CE mid-run.
	always @(posedge clk) begin
		if (reset) begin
			sel_lat   <= sel_eff;
			field_odd <= 1'b0;
		end else if (fstart) begin
			if (FAULT_NO_FIELD)
				field_odd <= 1'b0;
			else if (sel_lat == 2'd2)
				field_odd <= ~field_odd;
			else
				field_odd <= 1'b0;
		end
	end
endmodule
