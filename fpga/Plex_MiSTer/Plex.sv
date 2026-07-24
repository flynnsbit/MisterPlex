//============================================================================
//  MiSTerPlex — native Plex present core
//  Phase 1: color bars + cadence + tone
//  Phase 3.0: dual-bank RGB565 frame_store via ioctl F1
//  Phase 3.2: present-domain audio_fifo via ioctl F2
//  Phase 3.3: elementary bitstream FIFO + NAL scanner via ioctl F3
//  Phase 3.3b: NAL typed stats + decode_stub → frame_store on VCL
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
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

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
	"O[2],TV Mode,NTSC,PAL;",
	"O[5:4],Content FPS,24,30,60,12;",
	"O[7:6],Pattern,Bars,Bars+Block,Grid,Ramp;",
	"O[8],Audio tone,On,Off;",
	"O[9],Force bars (debug),No,Yes;",
	"T[10],Flush audio FIFO;",
	"T[11],Flush bitstream FIFO;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
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
	.fs_wr_en(stub_wr_en),
	.fs_wr_pixel(stub_wr_pixel),
	.fs_wr_reset(stub_wr_reset),
	.fs_swap(stub_swap)
);

// Mux F1 ingest vs decode_stub into single frame_store write port.
// Stub wins while busy (or when asserting write); F1 used for RGB path.
wire        fs_wr_en    = stub_busy ? stub_wr_en    : (stub_wr_en | f1_wr_en);
wire [15:0] fs_wr_pixel = stub_wr_en ? stub_wr_pixel : f1_wr_pixel;
wire        fs_wr_reset = stub_wr_reset | f1_wr_reset;
wire        fs_swap     = stub_swap | f1_swap;

wire ce_pix, HBlank, HSync, VBlank, VSync;
wire [7:0] r, g, b;
wire [15:0] al, ar_audio;
wire [31:0] disp_i, cont_i;
wire advance;

present_core present (
	.clk(clk_sys),
	.clk_audio(CLK_AUDIO),
	.reset(reset),
	.pal(status[2]),
	.scandouble(forced_scandoubler),
	.content_fps(content_fps),
	.display_hz(display_hz),
	.pattern(status[7:6]),
	.audio_en(~status[8]),
	.use_frame_store(status[9]),
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
	.stat_audio_underrun(audio_underrun)
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

// --- Core status → HPS (UIO_GET_STATUS) ---
// Layout (little-endian 16-bit words as read by ARM):
//   [0] has_frame  [1] has_audio  [2] has_stream  [3] audio_underrun
//   [4] has_idr    [5] stub_busy  [6] sps_valid  [7] pps_valid
//   [15:8] last_nal_type
//   [31:16] nalu_count
//   [47:32] stream_fifo_level
//   [55:48] first_mb_type  [63:56] slice_type
//   [71:64] slice_qp (in low of height if 0..51) — see [79:64] sps_height
//   [79:64] sps_height  [95:80] sps_width
//   [127:96] stream_bytes_in
//   [47:40] {residual_ok, residual_tc[4:0], residual_t1[1:0]}
//   [39:32] slice_qp
//   has_mb_type implied by first_mb_type<=25 after I-slice parse
assign status_in = {
	stream_bytes_in,                    // 127:96
	sps_width, sps_height,              // 95:64
	slice_type, first_mb_type,          // 63:48
	residual_ok, residual_tc, residual_t1, // 47:40
	{2'b0, slice_qp},                   // 39:32
	nalu_count,                         // 31:16
	last_nal_type,                      // 15:8
	pps_valid, sps_valid, stub_busy, has_idr, audio_underrun, has_stream, has_audio, has_frame
};

// Pulse status_set ~1 kHz or when nalu/sps/slice change so Main/ARM can poll.
reg [15:0] prev_nalu;
reg [7:0]  prev_sltype;
reg        prev_sps, prev_pps;
reg [14:0] st_div;
always @(posedge clk_sys) begin
	if (reset) begin
		status_set <= 0;
		prev_nalu  <= 0;
		prev_sltype <= 0;
		prev_sps   <= 0;
		prev_pps   <= 0;
		st_div     <= 0;
	end else begin
		status_set <= 0;
		st_div <= st_div + 1'd1;
		if (nalu_count != prev_nalu || slice_type != prev_sltype || sps_valid != prev_sps ||
		    pps_valid != prev_pps || st_div == 0) begin
			status_set <= 1'b1;
			prev_nalu  <= nalu_count;
			prev_sltype <= slice_type;
			prev_sps   <= sps_valid;
			prev_pps   <= pps_valid;
		end
	end
end

// Silence unused
wire _unused = |{disp_i, cont_i, advance, ingest_pixels, ingest_dl, af_active, ioctl_addr,
	sps_count, pps_count, slice_count, wr_count, stream_bytes_seen, sps_profile, sps_level,
	stub_frames, slice_valid, slice_is_i, sps_mb_w, sps_mb_h, has_mb_type, idr_count,
	stream_fifo_level};

endmodule
