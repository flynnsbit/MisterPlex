// plex_720p_bw_contract.svh — ONE agreed 720p24 bandwidth contract (three-lane).
// Coordinate: w-mem + w-clock + w-scaler. Do not invent a second B/clk number.
// Clocks (pll_0002.v SoT): clk_sys=20e6, clk_ddr=90e6.
// Shipping glass: MULTI + PPC=2 + clk_pix@29.7e6, clk_sys@20e6.
//
// Numbers lock with misterplex_bw_contract.svh (w-clock SoT stamp) and
// tests/fixtures/p720_bw_contract.json. P720_* names match w-mem consumers.
//
// STATUS SPLIT (rd-duck; do not collapse / do not say bare CLOSED):
//   reader TB class: STRESS_EVIDENCE (825*750@20M ~32.3fps; not product rate-match).
//   reader_payload_beat_delta_TB: MEASURED_TIGHT — G0 payload==173120 (=172800+2*160 Y),
//     Y/U/V=115520/28800/28800, returned==accepted, ddr_cy<3750000.
//   G1: payload==173120 (no 3x band) + ddr budget + busy/blocked (not wall-time).
//   G2 NEG: starve_dout after prep → steady deadline fail (discrimination proven).
//   reader_delivery_correctness: OPEN (G0 underrun_delta=77; no pixel checksum).
//   hps_write_concurrent + T_copy_e2e: OPEN (w-mem / w-path / parent)
//   Forbidden: reader CLOSED; fabric_bw_closed; fit_blocker_release by this TB.
// 33.1776/66.3552 = frame-store payload / ideal 64b port math ONLY.
// NOT measured sustainable DDR BW; NOT total controller traffic with HPS write.

`ifndef PLEX_720P_BW_CONTRACT_SVH
`define PLEX_720P_BW_CONTRACT_SVH

`include "misterplex_bw_contract.svh"

localparam int P720_CODED_W           = MISTERPLEX_BW_CODED_W;           // 1280
localparam int P720_CODED_H           = MISTERPLEX_BW_CODED_H;           // 720
localparam int P720_I420_BYTES        = MISTERPLEX_BW_I420_B_FRAME;      // 1382400
localparam int P720_Y_LINE_BYTES      = 1280;
localparam int P720_Y_LINE_QWORDS     = 160;
localparam int P720_C_LINE_QWORDS     = 80;
localparam int P720_BANK_STRIDE       = 32'h0018_0000;
localparam int P720_DOORBELL_PHYS     = 32'h3047_F000;
localparam int P720_PHYS_BASE         = 32'h3018_0000;
localparam int P720_FPS               = MISTERPLEX_BW_FPS;               // 24
localparam int P720_CLK_SYS_HZ        = MISTERPLEX_BW_CLK_SYS_HZ;        // 20e6
localparam int P720_CLK_DDR_HZ        = 90_000_000;
localparam int P720_CLK_PIX_HZ        = MISTERPLEX_BW_CLK_PIX_HZ;        // 29.7e6
localparam int P720_PPC               = MISTERPLEX_BW_PRODUCT_PPC;       // 2
localparam int P720_LINE_COUNT        = 16;
localparam int P720_FRAME_US          = MISTERPLEX_BW_FRAME_BUDGET_US;   // 41667
localparam int P720_DDR_CYC_PER_FRAME = 3_750_000; // 90e6/24
localparam int P720_FABRIC_RD_BPS     = MISTERPLEX_BW_DIR_B_PER_S;       // 33177600
localparam int P720_HOST_WR_BPS       = MISTERPLEX_BW_DIR_B_PER_S;
localparam int P720_HOST_COPY_US      = MISTERPLEX_BW_T_COPY_ARM_US;     // 14978
localparam int P720_COMBINED_AVG_BPS  = 2 * P720_FABRIC_RD_BPS;          // 66355200
localparam int P720_BEATS_PER_FRAME   = MISTERPLEX_BW_BEATS_PER_FRAME;   // 172800
localparam int P720_BEATS_RW_PAIR     = MISTERPLEX_BW_BEATS_RW_PAIR;     // 345600
// Blackout cover @ PPC2 / 20 MHz / 1280: 8 lines=256µs FAIL model; 16=512µs PASS
localparam int P720_BLACKOUT_US_16    = 512;
localparam int P720_BLACKOUT_US_8     = 256;
// NACK: 3.0 B/clk_sys DE peak is linebuf I420-equiv (rd_miss_now hit→no DDRAM)
localparam int P720_NACK_DE_PEAK_E1   = MISTERPLEX_BW_NACK_DE_PEAK_E1;   // 30

`endif // PLEX_720P_BW_CONTRACT_SVH
