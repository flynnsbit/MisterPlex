// h264_dpb_ddr_params.svh — DPB1 DDR map (consume w-mem ABI; do not redefine present).
// Include inside each module that needs the constants (no include-guard — localparams
// are per-module scope; a guard would blank the second consumer in one CU).
//
// Source: docs/dpb-ddr-design.md (w-mem reservation)
//   DDR_DPB_PHYS_BASE   = 0x3070_0000
//   DDR_DPB_BANK_STRIDE = 0x0018_0000
// Present doorbell 0x3047F000 / present base 0x30180000 are NOT DPB.
//
// Product SPS (measured): profile_idc=66 level_idc=30 max_num_ref_frames=1

`ifndef ENABLE_DPB_DDR
`define ENABLE_DPB_DDR 0
`endif

localparam int unsigned H264_DPB_DDR_PHYS_BASE   = 32'h3070_0000;
localparam int unsigned H264_DPB_DDR_BANK_STRIDE = 32'h0018_0000;
localparam int unsigned H264_DPB_DDR_BANK0       = 32'h3070_0000;
localparam int unsigned H264_DPB_DDR_BANK1       = 32'h3070_0000 + 32'h0018_0000;
localparam int unsigned H264_DPB_DDR_BYTES_MAX   = 1_382_400;
localparam int unsigned H264_DPB_NUM_REF_FRAMES  = 1;

localparam int unsigned H264_DPB_WIN_Y_BYTES = 21 * 21;
localparam int unsigned H264_DPB_WIN_C_BYTES = 9 * 9;
localparam int unsigned H264_DPB_WIN_TOTAL   = (21 * 21) + 2 * (9 * 9);

// Fetch geometry (h264_dpb_one_ref PH_LUMA/U/V) — quoted from h264_dpb.sv:
//   issue_idx ends 440 (21*21-1), 80 (9*9-1), 80; one-byte mem_rd each.
// part_w/part_h are latched but NOT used to narrow (lat_part_*_lo observe-only).
localparam int unsigned H264_DPB_FETCH_Y_SAMPLES = 21 * 21; // 441
localparam int unsigned H264_DPB_FETCH_C_SAMPLES = 9 * 9;   // 81
localparam int unsigned H264_DPB_FETCH_SAMPLES_P16 =
	H264_DPB_FETCH_Y_SAMPLES + 2 * H264_DPB_FETCH_C_SAMPLES; // 603

// 720p MB grid
localparam int unsigned H264_DPB_MB_720P = (1280 / 16) * (720 / 16); // 80*45=3600

// clk_sys product (STA-proven 20 MHz)
localparam int unsigned H264_DPB_CLK_SYS_HZ = 20_000_000;
localparam int unsigned H264_DPB_FRAME_BUDGET_24FPS_CYC =
	H264_DPB_CLK_SYS_HZ / 24; // 833_333

// Wide row fetch: 8-byte beats. Luma row 21 → ceil(21/8)=3 beats/row * 21 = 63
// Chroma row 9 → ceil(9/8)=2 beats/row * 9 = 18 per plane.
localparam int unsigned H264_DPB_WIDE_BEAT_BYTES = 8;
localparam int unsigned H264_DPB_WIDE_Y_BEATS = 3 * 21; // 63
localparam int unsigned H264_DPB_WIDE_C_BEATS = 2 * 9;  // 18
localparam int unsigned H264_DPB_WIDE_BEATS_P16 =
	H264_DPB_WIDE_Y_BEATS + 2 * H264_DPB_WIDE_C_BEATS; // 99
