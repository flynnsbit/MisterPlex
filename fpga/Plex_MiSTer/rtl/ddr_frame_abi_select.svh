// Shared DDR frame-store ABI selection.
//
// Include AFTER ddr_frame_layout_params.svh and AFTER FRAME_W / FRAME_H are
// visible as parameters (or macros) in the including module.
//
// Product silicon (default): DDR_FRAME_* — now 1280×720 @ phys 0x30000000 /
// doorbell 0x302FF000. Do NOT map FRAME_W==1280 onto Option-C dual-header
// (DDR_FRAME_720P_* @ 0x30180000 / 0x3047F000); that is opt-in only.
//
// Option-C dual-header map: define PLEX_DDR_ABI_OPTION_C (or legacy
// PLEX_DDR_ABI_720P) at the including site.
//
// No include-guard: each module include must elaborate its own localparams.

`ifdef PLEX_DDR_ABI_OPTION_C
	localparam bit DDR_FS_USE_OPTION_C = 1'b1;
`elsif PLEX_DDR_ABI_720P
	// Legacy force name kept as alias for Option-C dual-header map.
	localparam bit DDR_FS_USE_OPTION_C = 1'b1;
`else
	localparam bit DDR_FS_USE_OPTION_C = 1'b0;
`endif

// Historical name: "720p ABI" now means product canvas when not Option-C.
// Kept so call sites checking DDR_FS_USE_720P_ABI for line-floor still work
// when FRAME is 1280×720 product.
localparam bit DDR_FS_USE_720P_ABI =
	DDR_FS_USE_OPTION_C || ((FRAME_W == 1280) && (FRAME_H == 720));

localparam int DDR_FS_CODED_W =
	DDR_FS_USE_OPTION_C ? DDR_FRAME_720P_CODED_WIDTH : DDR_FRAME_CODED_WIDTH;
localparam int DDR_FS_CODED_H =
	DDR_FS_USE_OPTION_C ? DDR_FRAME_720P_CODED_HEIGHT : DDR_FRAME_CODED_HEIGHT;
localparam int DDR_FS_DISPLAY_W =
	DDR_FS_USE_OPTION_C ? DDR_FRAME_720P_DISPLAY_WIDTH : DDR_FRAME_DISPLAY_WIDTH;
localparam int DDR_FS_DISPLAY_H =
	DDR_FS_USE_OPTION_C ? DDR_FRAME_720P_DISPLAY_HEIGHT : DDR_FRAME_DISPLAY_HEIGHT;
localparam int DDR_FS_CROP_LEFT =
	DDR_FS_USE_OPTION_C ? 0 : DDR_FRAME_CROP_LEFT;
localparam int DDR_FS_CROP_TOP =
	DDR_FS_USE_OPTION_C ? 0 : DDR_FRAME_CROP_TOP;
localparam int DDR_FS_PRESENT_X =
	DDR_FS_USE_OPTION_C ? DDR_FRAME_720P_PILLARBOX_LEFT : DDR_FRAME_PILLARBOX_LEFT;
localparam int DDR_FS_PRESENT_Y = 0;
localparam [31:0] DDR_FS_PHYS_BASE =
	DDR_FS_USE_OPTION_C ? 32'(DDR_FRAME_720P_PHYS_BASE) : 32'(DDR_FRAME_PHYS_BASE);
localparam int DDR_FS_BANK_STRIDE =
	DDR_FS_USE_OPTION_C ? DDR_FRAME_720P_YUV420P_BANK_STRIDE
	                    : DDR_FRAME_YUV420P_BANK_STRIDE;
localparam [31:0] DDR_FS_DOORBELL =
	DDR_FS_USE_OPTION_C ? 32'(DDR_FRAME_720P_YUV420P_DOORBELL_PHYS)
	                    : 32'(DDR_FRAME_YUV420P_DOORBELL_PHYS);

// 720p blackout model: floor LINE_COUNT to 16 on 720p glass unless more requested.
`ifdef DDR_FS_APPLY_LINE_FLOOR
// 720p product floor tracks P720_LINE_COUNT (16 after line32 FIT_FAIL shelve).
localparam int DDR_FS_LINE_COUNT =
	(DDR_FS_USE_720P_ABI && (FRAME_LINE_COUNT < 16)) ? 16 : FRAME_LINE_COUNT;
`endif
