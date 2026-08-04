// MODULE-LOCAL include only: NO global `ifndef guard.
// localparams must re-expand in every consumer module scope.
// Global guards break multi-module compile (first include wins, rest undefined).
// Do NOT list this .svh as a standalone files.qip SYSTEMVERILOG_FILE.
// plex_720p_bw_contract.svh — ONE agreed 720p24 bandwidth contract (three-lane).
// Coordinate: w-mem + w-clock + w-scaler. Do not invent a second B/clk number.
// Clocks (pll_0002.v SoT): clk_sys=20e6, clk_ddr=90e6.
// Shipping glass: MULTI + PPC=2 + clk_pix@29.7e6, clk_sys@20e6.
//
// Numbers lock with misterplex_bw_contract.svh (w-clock SoT stamp) and
// tests/fixtures/p720_bw_contract.json. P720_* names match w-mem consumers.
//
// CLAIM_SPLIT (rd-duck final):
//   reader accepted-request steady delta: OBSERVED/CLOSED
//   reader PPC2 delivery/correctness/deadline: OPEN
//   shared fabric BW: OPEN
// Arithmetic lock only: 33.1776 MB/s/dir (=33177600 B/s). NACK unnormalized 38.53.
// audit_ack: rd-duck ACK = arithmetic labels ONLY — not reader CLOSED, not 38.53.
// Forbidden: free core; ARM never touches payload; bare reader CLOSED; fabric_bw_closed.
// Must be `include`d and bound into FS_*/store params or synthesis-active gates
// (QIP listing alone is dead compilation-unit work — not fabric).

`include "misterplex_bw_contract.svh"

localparam int P720_CODED_W           = MISTERPLEX_BW_CODED_W;           // 1280
localparam int P720_CODED_H           = MISTERPLEX_BW_CODED_H;           // 720
// Literals locked here (gate tokens 1_382_400 / 14_978); must equal SoT stamp.
localparam int P720_I420_BYTES        = 1_382_400; // == MISTERPLEX_BW_I420_B_FRAME
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
localparam int P720_HOST_COPY_US      = 14_978; // == MISTERPLEX_BW_T_COPY_ARM_US
// Cross-check SoT (elab-time dead modules if drift).
if (P720_I420_BYTES != MISTERPLEX_BW_I420_B_FRAME) begin : g_p720_i420_sot
	p720_i420_must_match_misterplex_bw_sot u_p720_i420_sot();
end
if (P720_HOST_COPY_US != MISTERPLEX_BW_T_COPY_ARM_US) begin : g_p720_tcopy_sot
	p720_tcopy_must_match_misterplex_bw_sot u_p720_tcopy_sot();
end
localparam int P720_COMBINED_AVG_BPS  = 2 * P720_FABRIC_RD_BPS;          // 66355200
localparam int P720_BEATS_PER_FRAME   = MISTERPLEX_BW_BEATS_PER_FRAME;   // 172800
localparam int P720_BEATS_RW_PAIR     = MISTERPLEX_BW_BEATS_RW_PAIR;     // 345600
// Blackout cover @ PPC2 / 20 MHz / 1280: 8 lines=256µs FAIL model; 16=512µs PASS
localparam int P720_BLACKOUT_US_16    = 512;
localparam int P720_BLACKOUT_US_8     = 256;
// NACK: 3.0 B/clk_sys DE peak is linebuf I420-equiv (rd_miss_now hit→no DDRAM)
localparam int P720_NACK_DE_PEAK_E1   = MISTERPLEX_BW_NACK_DE_PEAK_E1;   // 30

