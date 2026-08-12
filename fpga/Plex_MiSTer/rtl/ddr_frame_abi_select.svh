// Shared DDR frame-store ABI selection (w-clock / rd-duck BLOCKING).
//
// Include AFTER ddr_frame_layout_params.svh and AFTER FRAME_W / FRAME_H are
// visible as parameters (or macros) in the including module.
//
// 720p tier when:
//   - FRAME_W==1280 && FRAME_H==720  (L4 or MULTI product recipes), OR
//   - `PLEX_DDR_ABI_720P` forced on (explicit override)
//
// Do NOT gate 720p bank/doorbell/stride on PLEX_PRESENT_720P_L4 alone —
// PRESENT_MULTI_PIXEL is mutually exclusive with L4 but still needs the
// 720p DDR ABI when scanning a 1280×720 store.
//
// No include-guard: each module include must elaborate its own localparams
// (two probes in one TB would break under ifndef).

`ifdef PLEX_DDR_ABI_720P
	localparam bit DDR_FS_USE_720P_ABI = 1'b1;
`else
	localparam bit DDR_FS_USE_720P_ABI = (FRAME_W == 1280 && FRAME_H == 720);
`endif

localparam int DDR_FS_CODED_W =
	DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_CODED_WIDTH : DDR_FRAME_CODED_WIDTH;
localparam int DDR_FS_CODED_H =
	DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_CODED_HEIGHT : DDR_FRAME_CODED_HEIGHT;
localparam int DDR_FS_DISPLAY_W =
	DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_DISPLAY_WIDTH : DDR_FRAME_DISPLAY_WIDTH;
localparam int DDR_FS_DISPLAY_H =
	DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_DISPLAY_HEIGHT : DDR_FRAME_DISPLAY_HEIGHT;
localparam int DDR_FS_CROP_LEFT =
	DDR_FS_USE_720P_ABI ? 0 : DDR_FRAME_CROP_LEFT;
localparam int DDR_FS_CROP_TOP =
	DDR_FS_USE_720P_ABI ? 0 : DDR_FRAME_CROP_TOP;
localparam int DDR_FS_PRESENT_X =
	DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_PILLARBOX_LEFT : DDR_FRAME_PILLARBOX_LEFT;
localparam int DDR_FS_PRESENT_Y = 0;
localparam [31:0] DDR_FS_PHYS_BASE =
	DDR_FS_USE_720P_ABI ? 32'(DDR_FRAME_720P_PHYS_BASE) : 32'(DDR_FRAME_PHYS_BASE);
localparam int DDR_FS_BANK_STRIDE =
	DDR_FS_USE_720P_ABI ? DDR_FRAME_720P_YUV420P_BANK_STRIDE
	                    : DDR_FRAME_YUV420P_BANK_STRIDE;
localparam [31:0] DDR_FS_DOORBELL =
	DDR_FS_USE_720P_ABI ? 32'(DDR_FRAME_720P_YUV420P_DOORBELL_PHYS)
	                    : 32'(DDR_FRAME_YUV420P_DOORBELL_PHYS);

// 720p blackout model (docs/display-resolution.md): 500 µs class needs 16 lines
// at PPC=2 / 20 MHz (8 lines ≈ 256 µs). Floor LINE_COUNT to 16 on 720p ABI
// unless the including module already requested more.
// Requires FRAME_LINE_COUNT parameter in including scope when used.
`ifdef DDR_FS_APPLY_LINE_FLOOR
localparam int DDR_FS_LINE_COUNT =
	(DDR_FS_USE_720P_ABI && (FRAME_LINE_COUNT < 16)) ? 16 : FRAME_LINE_COUNT;
`endif
