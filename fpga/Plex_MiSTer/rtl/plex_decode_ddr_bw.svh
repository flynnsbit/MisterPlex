// plex_decode_ddr_bw.svh — multi-client DDR payload averages @720p24 (w-mem).
// Units: bytes, MB/s (=1e6 B/s), clk ticks. Do NOT confuse RATE with CPU TIME.
// Source arithmetic: Memory/lab/agents/w-mem-DECODE_DDR_ARB_BW.md
// Ideal port peak 90e6*8=720 MB/s is arithmetic ONLY — not measured sustainable DDR.
//
// LIVE vs DDR (parent reachability correction — verify before assuming traffic):
//   h264_dpb_one_ref / MC helpers are LIVE under decode_stub (source graph), but
//   decode_stub backs DPB with on-chip BRAM (`(* ram_style="block" *) dpb_mem`),
//   not DDRAM ports. So LIVE MC/DPB ≠ current external DDR load.
//   PDEC_DPB_* below are FUTURE external-DDR rates once w-fitgate moves the DPB
//   off BRAM. Product DDR masters today: m0 present, m1 bitstream|PLXG, m2 fabric_attach.
//   Bitstream (a) already exists as m1; budget below is still NOT a measured rate.
`ifndef PLEX_DECODE_DDR_BW_SVH
`define PLEX_DECODE_DDR_BW_SVH

localparam int PDEC_I420_BYTES          = 1_382_400;
localparam int PDEC_FPS                 = 24;
localparam int PDEC_CLK_SYS_HZ          = 20_000_000;
localparam int PDEC_CLK_DDR_HZ          = 90_000_000;
localparam int PDEC_BEAT_BYTES          = 8;

// (c) present read — hard realtime display path (product m0 today)
localparam int PDEC_PRESENT_RD_BPS      = PDEC_I420_BYTES * PDEC_FPS; // 33177600
// (b) DPB reconstructed frame write — FUTURE external DDR (BRAM today)
localparam int PDEC_DPB_WR_BPS          = PDEC_I420_BYTES * PDEC_FPS; // 33177600
// (b) DPB MC read — I-frame-only fabric path = 0 (P-frame OPEN); also BRAM today
localparam int PDEC_DPB_RD_MC_I_BPS     = 0;
// (a) bitstream — product m1 exists; 2 MB/s is design budget NOT measured
localparam int PDEC_BITSTREAM_BPS_BUDGET = 2_000_000;

localparam int PDEC_SUM_I_ONLY_BPS =
	PDEC_PRESENT_RD_BPS + PDEC_DPB_WR_BPS + PDEC_DPB_RD_MC_I_BPS + PDEC_BITSTREAM_BPS_BUDGET;
// 33177600+33177600+0+2000000 = 68355200 B/s

localparam int PDEC_IDEAL_PORT_PEAK_BPS = PDEC_CLK_DDR_HZ * PDEC_BEAT_BYTES; // 720e6

// Present line cover @ PPC2/20MHz LINE=16 (blackout prefetch budget)
localparam int PDEC_LINE_SYS_CYC_PPC2   = 640;           // 1280/2
localparam int PDEC_LINE_COUNT_MIN      = 16;
localparam int PDEC_BLACKOUT_SYS_CYC    = PDEC_LINE_COUNT_MIN * PDEC_LINE_SYS_CYC_PPC2; // 10240
// ddr cycles in same wall time: * (90/20) = *4.5
localparam int PDEC_BLACKOUT_DDR_CYC    = (PDEC_BLACKOUT_SYS_CYC * 9) / 2; // 46080

// Arbiter WC: low-priority burst clamp (beats). Present wait ≤ this + pipe.
localparam int PDEC_MAX_LOPRI_BURST     = 16;
// rsp_valid register + grant decision + busy sample ≤ 4 ddr cycles typical pipe
localparam int PDEC_ARB_PIPE_DDR_CYC    = 4;
localparam int PDEC_PRESENT_WC_DDR_CYC  = PDEC_MAX_LOPRI_BURST + PDEC_ARB_PIPE_DDR_CYC; // 20
// 20 / 90e6 = 222.2 ns << 512 µs blackout — bound holds with LINE=16 cover.

`endif
