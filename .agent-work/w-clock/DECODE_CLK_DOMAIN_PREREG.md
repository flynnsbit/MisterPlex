# Decoder clock domain — pre-registered predictions (BEFORE evidence)

Date: 2026-08-03
Lane: w-clock

## Throughput wall (parent awk — accept as given, re-verify)
| Geom | fps | cy/MB@20 | cy/MB@50 | vs ~2200 CAVLC |
|------|-----|----------|----------|----------------|
| 624x480 | 24 | 712 | 1780 | 20M: 3.1× short; 50M: 1.24× short |
| 320x240 | 24 | 2778 | 6944 | 20M OK-ish; 50M comfortable |

## Predictions (publish miss after evidence)

| ID | Prediction | Basis (pre-read) |
|----|------------|------------------|
| P1 | Decode path today sits on **clk_sys (20 MHz)** same as beam/present | Prior PLL SoT; product single fabric clk |
| P2 | PLL outputs: clk_sys ~20, clk_ddr ~90, maybe clk_audio; **no dedicated decode clk** | pll_0002.v prior work |
| P3 | Spare PLL C-counter or reconfig possible for ~50 MHz from 50 MHz ref | Cyclone V PLL typically 4–5 outputs; unknown until read |
| P4 | **Achievable decode-domain Fmax prediction: 40–55 MHz** on nostub-class netlist if decode is not on critical path of stub Fmax 23.46; **if decode shares stub critical path, Fmax ≤25 MHz** and 50 MHz is dead | Stub Fmax was whole-design; decode_top may differ |
| P5 | Frame store write already crosses to **clk_ddr (90 MHz)** domain via existing CDC/FIFO — decoder→store may already be multi-clock or same-clock as present | Need read ddr_frame_store / arbiter |
| P6 | Adding clk_dec @50 MHz is **not free**: new CDC decoder→DDR writer, STA on dec domain, possible Avalon/HPS coupling | |
| P7 | Even @50 MHz, 624x480@24 still **1.24× short** vs 2200 cy/MB unless cy/MB diet OR slice parallelism OR residual skip — **50 MHz alone does not close dominant class** | Arithmetic |

## What would kill this idea
- Decode already on critical path with Fmax < 35 MHz (measured STA)
- Write path hard-tied to clk_sys with no clean CDC seam
- 50 MHz still short and no credible cy/MB path → prefer diet/parallel over PLL

## Explicit non-claims until evidence
- No Fmax number without STA report quote
- No "should meet timing"

---

## Scorecard after evidence (2026-08-03)

| ID | Result | Note |
|----|--------|------|
| P1 | **HIT** | stream_path/decode on clk_sys 20 |
| P2 | **HIT** | no clk_dec |
| P3 | **HIT** | outclk_4+ @ 0 MHz spare |
| P4 | **MISS** | stub cone ~23.5 MHz; h264_decode_top Fmax **unknown** (not in qip); nostub 32.59 ≠ decode |
| P5 | **MISS** | store has sys↔ddr CDC but **no** fabric decode write under DDR_FRAME_STORE |
| P6 | **HIT** | third domain needs new FIFOs + STA |
| P7 | **HIT** | 50 MHz still 1.24× short @2200 cy/MB for 624@24 |

Full write-up: `DECODE_CLK_DOMAIN_VERDICT.md`
