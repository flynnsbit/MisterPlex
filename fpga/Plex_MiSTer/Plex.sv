//============================================================================
//  MiSTerPlex — native Plex present core (Phase 1)
//  FPGA owns vsync present, cadence (3:2/2:2), and continuous audio tone.
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
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[2],TV Mode,NTSC,PAL;",
	"O[5:4],Content FPS,24,30,60,12;",
	"O[7:6],Pattern,Bars,Bars+Block,Grid,Ramp;",
	"O[8],Audio tone,On,Off;",
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

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(0),
	.ps2_key(ps2_key)
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
	.stat_advance(advance)
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

// Heartbeat LED; faster blink when unique frames advance often
reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

// Silence unused warnings for stats until HPS status path is wired
wire _unused = |{disp_i, cont_i, advance};

endmodule
