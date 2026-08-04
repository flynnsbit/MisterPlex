// misterplex_bw_contract.svh — shared 720p24 I420 bandwidth SoT (w-clock).
// Headline is average full-frame direction rate, NOT DE-peak PPC*1.5 as DDR.
// Include from RTL/status modules only; do not redefine these locals elsewhere.
// P720_* aliases live in plex_720p_bw_contract.svh (three-lane name lock w-mem).
//
// NACK: "3.0 B/clk_sys" (PPC*1.5 during DE) is linebuf pixel I420-equivalent,
// not DDRAM beats. See ddr_frame_store rd_miss_now / fill-path DDRAM_RD.
//
// STATUS SPLIT: reader_payload_beat_delta_TB MEASURED; delivery/HPS/T_copy OPEN.
// Forbidden: unsplit fabric_bw_closed; bare "reader CLOSED".

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

// Parent Sweep 118 — CPU TIME is not a payload RATE (rd-duck / w-path).
// T_copy_arm = 14.978 ms/frame @ 88.0 MiB/s uncached /dev/mem for 1382400 B.
// Frame budget 41.667 ms; decode ~32.705 ms → headroom 8.962 ms → SERIAL DEFICIT ~6.0 ms.
// These are documentation integers for fabric-DMA motivation; not DDR beats.
localparam int MISTERPLEX_BW_FRAME_BUDGET_US   = 41667;  // 1000/24 ms → µs
localparam int MISTERPLEX_BW_T_COPY_ARM_US     = 14978;  // parent HW
localparam int MISTERPLEX_BW_DECODE_MS_X1000   = 32705;  // 32.705 ms → µs
// Parent 2026-08-04: effective ARM capacity = ONE core (MiSTer framework owns the other
// at ~100% idle busy). Path (a) decode||copy overlap is not dual-core-feasible.
// Path (b) fabric DMA retires T_copy without a second ARM core — funded Path A.
localparam int MISTERPLEX_BW_EFFECTIVE_ARM_CORES = 1;
// PRE-REG (arithmetic on parent Sweep 116/118 only — not e2e measured):
// If fabric retires full T_copy_arm from ARM critical path and decode stays 32.705 ms:
//   margin = FRAME_BUDGET_US - DECODE = 41667 - 32705 = 8962 µs (+8.962 ms).
//   Was serial deficit 6.016 ms; swing = T_copy. ARM decode-vs-budget CLOSES under those IFs.
//   Does NOT claim product e2e / fabric_bw / PPC2 closed.
localparam int MISTERPLEX_BW_AFTER_COPY_RETIRE_MARGIN_US = 8962;

`endif // MISTERPLEX_BW_CONTRACT_SVH
