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
