// misterplex_bw_contract.svh — shared 720p24 I420 bandwidth SoT (w-clock).
// Headline is average full-frame direction rate, NOT DE-peak PPC*1.5 as DDR.
// Include from RTL/status modules only; do not redefine these locals elsewhere.
//
// NACK: "3.0 B/clk_sys" (PPC*1.5 during DE) is linebuf pixel I420-equivalent,
// not DDRAM beats. See ddr_frame_store rd_miss_now / fill-path DDRAM_RD.

`ifndef MISTERPLEX_BW_CONTRACT_SVH
`define MISTERPLEX_BW_CONTRACT_SVH

// Geometry / frame (matches ddr_frame_layout_params.svh / host layout.hpp)
localparam int MISTERPLEX_BW_CODED_W           = 1280;
localparam int MISTERPLEX_BW_CODED_H           = 720;
localparam int MISTERPLEX_BW_FPS               = 24;
localparam int MISTERPLEX_BW_I420_B_FRAME      = 1_382_400; // 1280*720*3/2
localparam int MISTERPLEX_BW_BEAT_B            = 8;         // 64-bit DDRAM beat
localparam int MISTERPLEX_BW_BEATS_PER_FRAME   = 172_800;   // B_frame / 8
localparam int MISTERPLEX_BW_BEATS_RW_PAIR     = 345_600;   // write+read one frame

// clk_sys product (STA: keep 20; @24 FAIL stub-in Fmax 23.17)
localparam int MISTERPLEX_BW_CLK_SYS_HZ        = 20_000_000;

// Exact integer micros of MB/s * 1e6: B_frame * fps = 33_177_600 B/s
localparam int MISTERPLEX_BW_DIR_B_PER_S       = MISTERPLEX_BW_I420_B_FRAME * MISTERPLEX_BW_FPS;
// 33.1776 MB/s as milli-MB/s integer (33178 rounded) — prefer B/s above for exactness
localparam int MISTERPLEX_BW_DIR_MBPS_MILLI    = 33178; // display aid only

// Average B/clk_sys * 1e5 (1.65888 → 165888) so gates stay integer
// 33177600 / 20000000 = 1.65888 → *100000 = 165888
localparam int MISTERPLEX_BW_DIR_B_PER_CLK_E5  = 165888;

// Rejected as DDR headline (scaler DE peak I420-equiv)
localparam int MISTERPLEX_BW_NACK_DE_PEAK_E1   = 30; // 3.0 * 10

// Product present recipe (not a BW multiplier for DDR average)
localparam int MISTERPLEX_BW_PRODUCT_PPC       = 2;
localparam int MISTERPLEX_BW_CLK_PIX_HZ        = 29_700_000; // 1650*750*24

`endif // MISTERPLEX_BW_CONTRACT_SVH
