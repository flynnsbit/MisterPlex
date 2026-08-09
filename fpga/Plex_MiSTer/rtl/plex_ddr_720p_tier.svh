// Shared 720p DDR ABI tier select (w-mem / rd-duck BLOCKING MULTI↔L4 coupling).
//
// Include AFTER ddr_frame_layout_params.svh inside a module that defines
// FRAME_W / FRAME_H (present_core, TBs).
//
// L4 (`PLEX_PRESENT_720P_L4`) and MULTI (`PRESENT_MULTI_PIXEL`) are mutually
// exclusive as *beam* modes, but both need the Option-C 720p bank map when the
// store canvas is native 1280×720. Keying FS_CODED/PHYS/STRIDE/DOORBELL only on
// L4 left the shipping MULTI+PPC2+clk_pix recipe on 480p banks (624×480 /
// 0x30000000 / 0x80000 / 0x300FF000) while the CEA beam is 1280×720 — wrong
// doorbell and only 480p visibility.
//
// FAULT twin: `PLEX_DDR_720P_TIER_FAULT_FORCE_480` forces tier off so the unit
// gate can go RED if the select is bypassed.

`ifdef PLEX_DDR_720P_TIER_FAULT_FORCE_480
	localparam bit PLEX_DDR_720P_TIER = 1'b0;
`elsif PLEX_PRESENT_720P_L4
	localparam bit PLEX_DDR_720P_TIER = 1'b1;
`else
	// MULTI identity canvas, or any fit that sets FRAME to native 720p banks.
	localparam bit PLEX_DDR_720P_TIER = (FRAME_W == 1280) && (FRAME_H == 720);
`endif

localparam int FS_CODED_W     = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_CODED_WIDTH
                                                   : DDR_FRAME_CODED_WIDTH;
localparam int FS_CODED_H     = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_CODED_HEIGHT
                                                   : DDR_FRAME_CODED_HEIGHT;
localparam int FS_DISPLAY_W   = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_DISPLAY_WIDTH
                                                   : DDR_FRAME_DISPLAY_WIDTH;
localparam int FS_DISPLAY_H   = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_DISPLAY_HEIGHT
                                                   : DDR_FRAME_DISPLAY_HEIGHT;
localparam int FS_CROP_LEFT   = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_CROP_LEFT
                                                   : DDR_FRAME_CROP_LEFT;
localparam int FS_CROP_TOP    = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_CROP_TOP
                                                   : DDR_FRAME_CROP_TOP;
localparam int FS_PRESENT_X   = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_PILLARBOX_LEFT
                                                   : DDR_FRAME_PILLARBOX_LEFT;
localparam int FS_PRESENT_Y   = 0;
localparam [31:0] FS_PHYS_BASE = PLEX_DDR_720P_TIER ? DDR_FRAME_720P_PHYS_BASE
                                                   : 32'h3000_0000;
localparam int FS_BANK_STRIDE = PLEX_DDR_720P_TIER
	? DDR_FRAME_720P_YUV420P_BANK_STRIDE
	: DDR_FRAME_YUV420P_BANK_STRIDE;
localparam [31:0] FS_DOORBELL = PLEX_DDR_720P_TIER
	? DDR_FRAME_720P_YUV420P_DOORBELL_PHYS
	: DDR_FRAME_YUV420P_DOORBELL_PHYS;

// Linebufs: 8 lines @ 2 px/clk / 20 MHz over 1280 DE =
//   8 * (1280/2) / 20e6 = 256 µs blackout — below the modeled 500 µs floor.
// 16 lines → 512 µs. L4 QSF forces FRAME_LINES_16; MULTI must not keep 8.
localparam int FS_LINE_COUNT_MIN_720P = 16;
