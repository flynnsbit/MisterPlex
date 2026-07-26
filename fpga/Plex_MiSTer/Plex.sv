//============================================================================
//  MiSTerPlex — native Plex present core
//  Phase 1: color bars + cadence + tone
//  Phase 3.0: dual-bank RGB565 frame_store via ioctl F1
//  Phase 3.1b: DDRAM/f2sdram HPS bulk RGB565 → frame_store (beat SPI F1)
//  Phase 3.2: present-domain audio_fifo via ioctl F2
//  Phase 3.3: elementary bitstream FIFO + NAL scanner via ioctl F3
//  Phase 3.3b: NAL typed stats + decode_stub → frame_store on VCL
//  Phase 3.3j: hybrid host F1 owns present; stub residual paint F3-only
//  Phase 3.3k: first residual CAVLC levels/runs → residual_dc paint/status
//  Phase 3.3l-1: full coeff[0:15] place + residual_csum status (prep inv_quant)
//  Copyright (C) 2026 MiSTerPlex contributors
//  GPL-2.0-or-later (MiSTer core convention)
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Defaults for unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
// DDRAM driven by ddram_frame_rd (Phase 3.1b); not tied off.

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_MIX = 0;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Plex;;",
	"-;",
	"F1,rawRGB565 frame (320x240);",
	"F2,raw s16le stereo PCM @48k;",
	"F3,H.264 annex-B elementary;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// Default first option = NTSC (status[2]=0). Bump v, so saved PAL is cleared.
	"O[2],TV Mode,NTSC,PAL;",
	// O[5:4] Content FPS is written by misterplexd from the exact PMS frame rate,
	// so it is intentionally NOT a menu item.
	"-;",
	// misterplexd reads these back over UIO and applies them live (no restart).
	// 4-bit signed, 20 ms per step: index 0 = 0 ms, 8..15 = -160..-20 ms.
	"O[9:6],A/V offset,0ms,+20ms,+40ms,+60ms,+80ms,+100ms,+120ms,+140ms,-160ms,-140ms,-120ms,-100ms,-80ms,-60ms,-40ms,-20ms;",
	"O[1],A/V auto resync,On,Off;",
	"O[3],Audio clock trim,On,Off;",
	"O[15:14],Idle screen,Plex logo,Black,Screensaver,Last frame;",
	"-;",
	"T[10],Flush audio FIFO;",
	"T[11],Flush bitstream FIFO;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,3;", // reset OSD: v3 reclaims O[9:6],O[3],O[1],O[15:14] for playback controls
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;

// Core→HPS status (UIO_GET_STATUS / 0x29). See docs/phase3-decode.md layout.
wire [127:0] status_in;
reg          status_set;
wire         has_frame, has_audio, has_stream, audio_underrun;
wire         has_idr, stub_busy, sps_valid, pps_valid, slice_valid, slice_is_i, has_mb_type;
wire         residual_ok;
wire [15:0]  nalu_count, stub_frames, sps_width, sps_height;
wire [7:0]   last_nal_type, idr_count, sps_count, pps_count, slice_count;
wire [7:0]   sps_profile, sps_level, slice_type, sps_mb_w, sps_mb_h, first_mb_type;
wire [5:0]   slice_qp;
wire [4:0]   residual_tc;
wire [1:0]   residual_t1;
wire signed [7:0] residual_dc;
wire [7:0]   residual_csum;
wire signed [8:0] residual_coeff [0:15];
wire         residual_place_pulse;
wire [31:0]  stream_bytes_in, stream_bytes_seen;
wire [15:0]  stream_fifo_level;
wire [18:0]  wr_count;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_in(status_in),
	.status_set(status_set),
	.status_menumask(0),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys)
);

wire reset = RESET | status[0] | buttons[1];

// Map OSD content FPS
reg [7:0] content_fps;
always @(*) begin
	case (status[5:4])
		2'd0: content_fps = 8'd24;
		2'd1: content_fps = 8'd30;
		2'd2: content_fps = 8'd60;
		default: content_fps = 8'd12;
	endcase
end

wire [7:0] display_hz = status[2] ? 8'd50 : 8'd60; // PAL/NTSC family

// F1 = frame (1), F2 = audio (2), F3 = elementary bitstream (3)
wire is_frame_dl = (ioctl_index[5:0] == 6'd1);
wire is_audio_dl = (ioctl_index[5:0] == 6'd2);
wire is_stream_dl = (ioctl_index[5:0] == 6'd3);

// Frame ingest from F1
wire        f1_wr_en;
wire [15:0] f1_wr_pixel;
wire        f1_wr_reset;
wire        f1_swap;
wire [31:0] ingest_pixels;
wire        ingest_dl;

frame_ingest finst (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_dout(ioctl_dout),
	.ioctl_addr(ioctl_addr),
	.ioctl_index(ioctl_index),
	.enable(is_frame_dl),
	.wr_en(f1_wr_en),
	.wr_pixel(f1_wr_pixel),
	.wr_reset_ptr(f1_wr_reset),
	.swap_req(f1_swap),
	.pixels_written(ingest_pixels),
	.downloading(ingest_dl)
);

// Phase 3.1b: HPS mmap @ 0x30000000 → DDRAM burst → frame_store
// status[12]=start (rising edge), status[13]=bank (0/1)
// swap_pending comes from present_core/frame_store (declared below; wire OK early).
wire        ddr_wr_en;
wire [15:0] ddr_wr_pixel;
wire        ddr_wr_reset;
wire        ddr_swap;
wire        ddr_busy;
wire [15:0] ddr_frames;
wire        swap_pending;

ddram_frame_rd #(
	.WIDTH(320),
	.HEIGHT(240),
	.PHYS_BASE(32'h3000_0000),
	.BURST(32)
) ddr_fr (
	.clk(clk_sys),
	.reset(reset),
	.start_req(status[12]),
	.bank_sel(status[13]),
	.swap_pending(swap_pending),
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
	.wr_en(ddr_wr_en),
	.wr_pixel(ddr_wr_pixel),
	.wr_reset_ptr(ddr_wr_reset),
	.swap_req(ddr_swap),
	.busy(ddr_busy),
	.frames_done(ddr_frames)
);

// Audio ingest from F2
wire        af_wr_en;
wire [31:0] af_wr_data;
wire        af_wr_flush;
wire        af_active;

audio_ingest ainst (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.enable(is_audio_dl),
	.wr_en(af_wr_en),
	.wr_data(af_wr_data),
	.wr_flush(af_wr_flush),
	.active(af_active)
);

// Phase 3.3/3.3b/3.3c: annex-B → NAL stats → SPS parse + decode_stub → frame_store
wire        stub_wr_en;
wire [15:0] stub_wr_pixel;
wire        stub_wr_reset;
wire        stub_swap;

stream_path spath (
	.clk(clk_sys),
	.reset(reset),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_dout(ioctl_dout),
	.enable(is_stream_dl),
	.flush(status[11]),
	.has_stream(has_stream),
	.nalu_count(nalu_count),
	.last_nal_type(last_nal_type),
	.bytes_in(stream_bytes_in),
	.bytes_seen(stream_bytes_seen),
	.fifo_level(stream_fifo_level),
	.has_idr(has_idr),
	.idr_count(idr_count),
	.sps_count(sps_count),
	.pps_count(pps_count),
	.slice_count(slice_count),
	.stub_frames(stub_frames),
	.stub_busy(stub_busy),
	.sps_valid(sps_valid),
	.sps_profile(sps_profile),
	.sps_level(sps_level),
	.sps_width(sps_width),
	.sps_height(sps_height),
	.sps_mb_w(sps_mb_w),
	.sps_mb_h(sps_mb_h),
	.pps_valid(pps_valid),
	.slice_valid(slice_valid),
	.slice_type(slice_type),
	.slice_is_i(slice_is_i),
	.first_mb_type(first_mb_type),
	.has_mb_type(has_mb_type),
	.slice_qp(slice_qp),
	.residual_tc(residual_tc),
	.residual_t1(residual_t1),
	.residual_ok(residual_ok),
	.residual_dc(residual_dc),
	.residual_csum(residual_csum),
	.residual_coeff(residual_coeff),
	.residual_place_pulse(residual_place_pulse),
	.fs_wr_en(stub_wr_en),
	.fs_wr_pixel(stub_wr_pixel),
	.fs_wr_reset(stub_wr_reset),
	.fs_swap(stub_swap)
);

// Phase 3.3j / 3.1b hybrid present:
//   Host F1 SPI or DDR bulk owns product frame_store once any host frame has
//   swapped. decode_stub F3 diagnostic paint is suppressed after that.
//   Priority while writing: F1 ioctl download > DDR DMA > stub.
reg host_owns_fs;
always @(posedge clk_sys) begin
	if (reset)
		host_owns_fs <= 1'b0;
	else if (f1_swap | ddr_swap)
		host_owns_fs <= 1'b1;
end

wire        stub_allow  = ~host_owns_fs & ~ingest_dl & ~ddr_busy;
wire        host_wr     = ingest_dl | f1_wr_en | ddr_wr_en;
wire        fs_wr_en    = ingest_dl ? f1_wr_en
	                      : ddr_busy  ? ddr_wr_en
	                      : (stub_allow ? (stub_wr_en | f1_wr_en) : f1_wr_en);
wire [15:0] fs_wr_pixel = ingest_dl ? f1_wr_pixel
	                      : ddr_wr_en ? ddr_wr_pixel
	                      : (f1_wr_en ? f1_wr_pixel : stub_wr_pixel);
wire        fs_wr_reset = f1_wr_reset | ddr_wr_reset | (stub_wr_reset & stub_allow);
wire        fs_swap     = f1_swap | ddr_swap | (stub_swap & stub_allow);
wire        _host_wr_unused = host_wr;

wire ce_pix, HBlank, HSync, VBlank, VSync;
wire [7:0] r, g, b;
wire [15:0] al, ar_audio;
wire [31:0] disp_i, cont_i;
wire advance;
// swap_pending declared above (fed back into ddram_frame_rd hold-off)

present_core present (
	.clk(clk_sys),
	.clk_audio(CLK_AUDIO),
	.reset(reset),
	.pal(status[2]),
	.scandouble(forced_scandoubler),
	.content_fps(content_fps),
	.display_hz(display_hz),
	// v3 reclaimed the debug bits O[9:6]/O[8]/O[9] for playback controls, so the
	// pattern generator and the bars test tone are hardwired to their previous
	// defaults (Pattern=None, Audio tone=Off, Force bars=No).
	.pattern(2'd0),
	.audio_en(1'b0),
	.use_frame_store(1'b0),
	.fs_wr_en(fs_wr_en),
	.fs_wr_pixel(fs_wr_pixel),
	.fs_wr_reset(fs_wr_reset),
	.fs_swap(fs_swap),
	.af_wr_en(af_wr_en),
	.af_wr_data(af_wr_data),
	// OSD T[10] or SPI status bit 10 pulses flush
	.af_wr_flush(af_wr_flush | status[10]),
	.ce_pix(ce_pix),
	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),
	.r(r),
	.g(g),
	.b(b),
	.audio_l(al),
	.audio_r(ar_audio),
	.stat_display_index(disp_i),
	.stat_content_index(cont_i),
	.stat_advance(advance),
	.stat_has_frame(has_frame),
	.stat_wr_count(wr_count),
	.stat_has_audio(has_audio),
	.stat_audio_underrun(audio_underrun),
	.stat_swap_pending(swap_pending)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;
assign VGA_R  = r;
assign VGA_G  = g;
assign VGA_B  = b;

// Signed audio samples
assign AUDIO_S = 1;
assign AUDIO_L = al;
assign AUDIO_R = ar_audio;

// Heartbeat LED; faster blink with audio; very fast when bitstream NALs seen.
reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
wire led_base = has_frame ? act_cnt[24] : (act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0]);
assign LED_USER = has_stream ? (act_cnt[20] ^ nalu_count[0] ^ last_nal_type[0])
	: (has_audio ? act_cnt[22] : led_base);

// --- Core status → HPS (UIO_GET_STATUS / status_set) ---
//
// When status_set rises, Main_MiSTer *replaces* the entire OSD status word with
// status_in (then clears bit 0). Telemetry MUST NOT occupy CONF_STR O/T bits or
// Pattern / FPS / TV Mode freeze, and HPS status[12]/[13] DDR kick/bank survive.
//
// Layout v2 (OSD-safe, 128b):
//   [15:0]    status[15:0]     // OSD O/T + DDR start[12] bank[13]
//   [23:16]   flags            // has_frame..pps_valid
//   [31:24]   last_nal_type
//   [47:32]   nalu_count
//   [55:48]   first_mb_type    [63:56] slice_type
//   [71:64]   {residual_ok, residual_tc[4:0], residual_t1[1:0]}
//   [79:72]   {ddr_busy, swap_pending, slice_qp[5:0]}
//   [87:80]   sps_mb_w         [95:88] sps_mb_h  (pixels = mb*16)
//   [103:96]  residual_dc      (3.3k regression; clean of AR)
//   [111:104] residual_csum    (3.3l-1 XOR sat8(coeff[0:15]); Baseline golden 0x14)
//   [127:112] stream_bytes_in[15:0]  (was 24b; 16b enough for F3 bring-up)
//   [122:121] forced from status (Aspect ratio) — overlaps stream MSBs only
wire [7:0] telem_flags = {
	pps_valid, sps_valid, stub_busy, has_idr,
	audio_underrun, has_stream, has_audio, has_frame
};

// R-csum6 Rank1+2+3 product sticky residual pack (owner R-csum6; DIAG STRIPPED):
// Lab SoT H-gate-rcsum5: 8832824e MULTI_DRIVE +0x53/push; level res_pair_sticky FAIL.
// Intent: freeze published residual half ONLY on place completion (or ok-rise for tc=0).
//
// Rank1: st_res_word_sticky samples on residual_place_pulse (primary) or residual_ok_rise
//        (tc=0 / no-place paths). NEVER continuous/level while residual_ok (walk class).
// Rank2: residual half forced from sticky via status_telem_masked; stream ONLY [127:112].
// Rank3: slice residual_place_pulse + place_* private; product residual_csum<=cs at ST_PLACE.
// DIAG STRIPPED: no residual_csum<=8'h14 force (parent product path).
// Layout unchanged for ARM: raw[12]=dc, raw[13]=csum, raw[14:15]=stream LE.
(* preserve *) reg [15:0] st_res_word;         // live bond {csum,dc} debug ONLY — never status
(* preserve *) reg [15:0] st_res_word_sticky;  // ONLY status residual source {csum,dc}
(* preserve *) reg [15:0] st_stream_lo;        // stream lo debug; separate from residual
(* preserve *) reg [127:0] status_telem_r;
(* preserve *) reg        residual_ok_d_st;
wire residual_ok_rise = residual_ok & ~residual_ok_d_st;
wire [7:0] st_res_csum = st_res_word_sticky[15:8];
wire signed [7:0] st_res_dc = st_res_word_sticky[7:0];

// Always block A: residual sticky ONLY (inputs: place pulse / ok rise / residual_*)
// NEVER mentions stream_bytes_in — structural isolate Rank2.
always @(posedge clk_sys) begin
	if (reset) begin
		st_res_word        <= 16'd0;
		st_res_word_sticky <= 16'd0;
		residual_ok_d_st   <= 1'b0;
	end else begin
		st_res_word      <= {residual_csum, residual_dc}; // debug bond
		residual_ok_d_st <= residual_ok;
		// Primary: ST_PLACE pulse freezes place-time product pair (blocks +0x53 walk)
		if (residual_place_pulse)
			st_res_word_sticky <= {residual_csum, residual_dc};
		// Secondary: residual_ok rise for tc=0 / paths without ST_PLACE
		else if (residual_ok_rise)
			st_res_word_sticky <= {residual_csum, residual_dc};
		// else HOLD sticky — frozen between intentional place/ok edges
	end
end

// Always block B: stream lo debug ONLY
always @(posedge clk_sys) begin
	if (reset)
		st_stream_lo <= 16'd0;
	else
		st_stream_lo <= stream_bytes_in[15:0];
end

// Always block C: assemble status_telem from sticky residual + live stream half
always @(posedge clk_sys) begin
	if (reset) begin
		status_telem_r <= 128'd0;
	end else begin
		status_telem_r[15:0]    <= status[15:0];
		status_telem_r[23:16]   <= telem_flags;
		status_telem_r[31:24]   <= last_nal_type;
		status_telem_r[47:32]   <= nalu_count;
		status_telem_r[55:48]   <= first_mb_type;
		status_telem_r[63:56]   <= slice_type;
		status_telem_r[71:64]   <= {residual_ok, residual_tc, residual_t1};
		status_telem_r[79:72]   <= {ddr_busy, swap_pending, slice_qp};
		status_telem_r[87:80]   <= sps_mb_w;
		status_telem_r[95:88]   <= sps_mb_h;
		// residual half from sticky ONLY (never live residual_csum, never stream)
		status_telem_r[103:96]  <= st_res_word_sticky[7:0];
		status_telem_r[111:104] <= st_res_word_sticky[15:8];
		status_telem_r[127:112] <= stream_bytes_in[15:0];
	end
end

// Rank2 structural mask: force residual bytes from sticky before AR splice
wire [127:0] status_telem_masked = {
	status_telem_r[127:112],      // stream
	st_res_word_sticky[15:8],     // csum forced from sticky
	st_res_word_sticky[7:0],      // dc forced from sticky
	status_telem_r[95:0]
};

// Preserve Aspect ratio OSD bits (may stomp stream_bytes high bits — OK)
// status_set replaces entire word in Main; residual bits stay below AR splice.
assign status_in = {
	status_telem_masked[127:123],
	status[122:121],
	status_telem_masked[120:0]
};

// Pulse status_set ~1 kHz or when nalu/sps/slice/residual telem change so Main/ARM can poll.
reg [15:0] prev_nalu;
reg [7:0]  prev_sltype;
reg        prev_sps, prev_pps;
reg [7:0]  prev_csum;
reg signed [7:0] prev_dc;
reg [14:0] st_div;
always @(posedge clk_sys) begin
	if (reset) begin
		status_set <= 0;
		prev_nalu  <= 0;
		prev_sltype <= 0;
		prev_sps   <= 0;
		prev_pps   <= 0;
		prev_csum  <= 0;
		prev_dc    <= 0;
		st_div     <= 0;
	end else begin
		status_set <= 0;
		st_div <= st_div + 1'd1;
		if (nalu_count != prev_nalu || slice_type != prev_sltype || sps_valid != prev_sps ||
		    pps_valid != prev_pps || st_res_csum != prev_csum || st_res_dc != prev_dc ||
		    st_div == 0) begin
			status_set <= 1'b1;
			prev_nalu  <= nalu_count;
			prev_sltype <= slice_type;
			prev_sps   <= sps_valid;
			prev_pps   <= pps_valid;
			prev_csum  <= st_res_csum;
			prev_dc    <= st_res_dc;
		end
	end
end

// Silence unused
wire _unused = |{disp_i, cont_i, advance, ingest_pixels, ingest_dl, af_active, ioctl_addr,
	sps_count, pps_count, slice_count, wr_count, stream_bytes_seen, sps_profile, sps_level,
	// 3.3l-1: keep residual_coeff visible for inv_quant (3.3l-2); csum already in status
	residual_coeff[0], residual_coeff[1], residual_coeff[2], residual_coeff[3],
	residual_coeff[4], residual_coeff[5], residual_coeff[6], residual_coeff[7],
	residual_coeff[8], residual_coeff[9], residual_coeff[10], residual_coeff[11],
	residual_coeff[12], residual_coeff[13], residual_coeff[14], residual_coeff[15],
	stub_frames, slice_valid, slice_is_i, sps_mb_w, sps_mb_h, has_mb_type, idr_count,
	stream_fifo_level, ddr_frames, _host_wr_unused};

endmodule
