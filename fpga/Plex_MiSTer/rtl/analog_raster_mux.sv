// Runtime analog raster mux for the SD-family product RBF.
// clk_sys = 20 MHz. Integer CE only — no HDMI / ascal modeline.
//
// v1 (PHASE_BACKLOG): analog H class is RESET-LATCHED (core reset / daemon start).
// Mid-stream F12 Analog O[15:14], Content O[5:4] Follow, or a live HPS doorbell
// hop must NOT retarget H class until the next reset. Live fstart reload is
// RED ANALOG_RASTER_FAULT_LIVE_LATCH. Live doorbell hop is RED
// ANALOG_RASTER_FAULT_LIVE_DOORBELL. Content O[5:4] is DECODE, not analog.
//
// HPS analog doorbell (PLXH): 480p mailbox 0x3007F138, magic 0x504C5848.
// NOT leftover L4 PLXJ 0x3047F130. 2FF into clk_sys, snapshot on reset into
// sel_lat (doorbell wins when magic/valid; else OSD raster_sel). HPS writes
// PLXH, waits one idle poll, then pulses reset (status[0] / load_core).
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
// HDMI LCD must never take a 15 kHz ascal video_mode from this module.
// Analog VGA_F1 is the 480i field flag; VGA_SCALER stays 0 at the parent.

module analog_raster_mux (
	input  wire        clk,
	input  wire        reset,
	input  wire        pal,
	input  wire [1:0]  raster_sel,     // OSD Analog: 0=240p15, 1=480p31, 2=480i
	input  wire [1:0]  doorbell_sel,   // PLXH analog_sel (clk_ddr / TB; async)
	input  wire        doorbell_valid, // 1 = PLXH magic OK (sel 0..2)
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

	// 2FF clk_ddr PLXH → clk_sys. Do not reset these: snapshot-on-reset must
	// see the last polled doorbell. SDC false-paths db_sel_s1 / db_v_s1.
	reg [1:0] db_sel_s1, db_sel_s2;
	reg       db_v_s1, db_v_s2;
	always @(posedge clk) begin
		db_sel_s1 <= doorbell_sel;
		db_sel_s2 <= db_sel_s1;
		db_v_s1   <= doorbell_valid;
		db_v_s2   <= db_v_s1;
	end

	// sel 3 is reserved: fall back to OSD Analog (Follow / menu).
	wire        db_take   = db_v_s2 && (db_sel_s2 != 2'd3);
	wire [1:0]  db_or_osd = db_take ? db_sel_s2 : sel_eff;

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

	// sel_lat is reset-only (Plex_analog_mux.sdc). Live OSD O[15:14] /
	// Content Follow / PLXH hop must not retune CE mid-run.
	always @(posedge clk) begin
		if (reset) begin
			sel_lat   <= db_or_osd;
			field_odd <= 1'b0;
		end else begin
`ifdef ANALOG_RASTER_FAULT_LIVE_DOORBELL
			// RED twin: live-latches analog H class from the 2FF'd doorbell
			// (or OSD fallback) every clk — mid-stream hop retargets.
			sel_lat <= db_or_osd;
`endif
			if (fstart) begin
`ifdef ANALOG_RASTER_FAULT_LIVE_LATCH
				// RED twin: still live-latches analog H class at every frame_start.
				sel_lat <= sel_eff;
`endif
				if (FAULT_NO_FIELD)
					field_odd <= 1'b0;
				else if (sel_lat == 2'd2)
					field_odd <= ~field_odd;
				else
					field_odd <= 1'b0;
			end
		end
	end
endmodule
