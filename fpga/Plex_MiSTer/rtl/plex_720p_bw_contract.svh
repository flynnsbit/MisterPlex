// plex_720p_bw_contract.svh — ONE agreed 720p24 bandwidth contract (w-mem).
// Coordinate: w-mem + w-clock + w-scaler. Do not invent a second B/clk number.
// Clocks (pll_0002.v SoT): clk_sys=20e6, clk_ddr=90e6.
// Shipping glass: MULTI + PPC=2 + clk_pix@29.7e6, clk_sys@20e6.
//
// STATUS SPLIT (rd-duck binding — do not collapse):
//   reader_steady_delta: HARNESS_NOT_CLOSED (w-clock TB starting harness only).
//     G0 counts useful (total_rd=182809 etc); delivery/correctness OPEN until
//     G1 deadline+upper bound, underrun==0, dual-lane checksum, beat conservation,
//     RED negative stall. Synthetic scan ~32.3fps bypasses product rate-match.
//   fullframe_e2e_beat_delta: FILLED_companion_only (fd→fd + elapsed sys window).
//     38.53 MBps RETRACTED (was beats*8*24). NOT pure 33.1776 closed.
//   hps_write_concurrent + T_copy_e2e: OPEN (w-mem/w-path/parent)
//     HOST write is NOT f2sdram — archive /dev/mem 1382400 B = 14.978 ms/f CPU TIME
//   Path A on origin: dual-header + this contract file. Not product-wired yet
//   (no present_core include on origin/main until scaler/store coordinate).
//   Do NOT list in files.qip until a real `include consumer exists (rd-duck).
//   Forbidden: reader CLOSED; fabric_bw_closed; free-core-during-decode;
//     ARM-never-touches-frame; 38.53 as established rate; two free ARM cores.
// ARM capacity (parent /proc/stat 10s): MiSTer framework = 100% of one core at
// idle; mpx-main ~0.8%. Effective ARM for MiSTerPlex = ONE core. Decode||copy
// overlap is NOT free second-core parallel. 33.1776 DDR payload math unchanged.
// Serial 720p24: T_copy 14.978 ms still exceeds decode headroom even after
// framework renice (~12.97 ms) → ~2.01 ms/f deficit; closure = cut T_copy.
// rd-duck: 33.1776/66.3552/0.09216 = frame-store payload / ideal 64b port math ONLY.
// NOT measured sustainable DDR BW; NOT total controller traffic; HPS write not RTL beats.
//
localparam int P720_CODED_W           = 1280;
localparam int P720_CODED_H           = 720;
localparam int P720_I420_BYTES        = 1_382_400;
localparam int P720_Y_LINE_BYTES      = 1280;
localparam int P720_Y_LINE_QWORDS     = 160;
localparam int P720_C_LINE_QWORDS     = 80;
localparam int P720_BANK_STRIDE       = 32'h0018_0000;
localparam int P720_DOORBELL_PHYS     = 32'h3047_F000;
localparam int P720_FPS               = 24;
localparam int P720_CLK_SYS_HZ        = 20_000_000;
localparam int P720_CLK_DDR_HZ        = 90_000_000;
localparam int P720_CLK_PIX_HZ        = 29_700_000;
localparam int P720_PPC               = 2;
localparam int P720_LINE_COUNT        = 16;
localparam int P720_FRAME_US          = 41_667;
localparam int P720_DDR_CYC_PER_FRAME = 3_750_000;
localparam int P720_FABRIC_RD_BPS     = P720_I420_BYTES * P720_FPS; // 33177600
localparam int P720_HOST_WR_BPS       = P720_I420_BYTES * P720_FPS;
localparam int P720_HOST_COPY_US      = 14_978;
localparam int P720_COMBINED_AVG_BPS  = 2 * P720_FABRIC_RD_BPS;
// PPC=2 does NOT double frame DDR bytes. Refill ~240 qw/line avg @90MHz ≈2.67µs
// << glass line 55.56µs. LINE=16 → ~889µs look-ahead. Blackout 16*640/20e6=512µs.
localparam int P720_BLACKOUT_US_16    = 512;
localparam int P720_BLACKOUT_US_8     = 256;
// SDRAM: single stick — spill candidate only; sdram_line_spill is M10K stub not PHY.
