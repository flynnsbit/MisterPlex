# Decode throughput budget

This note is a realtime ratchet for the FPGA decode path. It deliberately
separates measured cost from unknown future cost; unknown stages are not counted
as free.

## Clock provenance (traced and verified 2026-07-27)

Every decode stage runs on a single clock domain. The chain is:

```
FPGA_CLK2_50 (50 MHz board osc)
 └─ pll_0002.v: altera_pll outclk_0 = "20.000000 MHz"     → clk_sys
    └─ Plex.sv line 215:   .outclk_0(clk_sys)
       └─ Plex.sv line 588: stream_path spath .clk(clk_sys)
          └─ stream_path.sv: every submodule gets .clk(clk)
             ├─ stream_ingest    .clk(clk)   line 103
             ├─ ddr_bitstream_reader .clk(clk) line 116
             ├─ bitstream_fifo   .clk(clk)   line 148
             ├─ nalu_scanner     .clk(clk)   line 164
             ├─ sps_parser       .clk(clk)   line 190
             ├─ pps_parser       .clk(clk)   line 205
             ├─ slice_hdr_parser .clk(clk)   line 232
             └─ decode_stub      .clk(clk)   line 293
```

**The decode clock is 20 MHz. There is no 100 MHz decode path.**

The 100 MHz SDRAM clock (`clk_sdram`, outclk_1) and 90 MHz DDR bridge clock
(`clk_ddr`, outclk_2) are separate outputs of the same PLL. They drive the
SDRAM controller and f2sdram bridge respectively, NOT the decode pipeline.

**Provenance of the "100 MHz / 3,418 cycles/MB" figure:** `docs/p3-mc-dpb-bandwidth.md`
used the SDRAM default clock (100 MHz) in the budget calculation instead of the
actual decode clock (20 MHz). This error has been corrected. The number had no
traced provenance — it was an assumption that was never verified against the RTL.

## Declared assumptions

| Parameter | Value | Source |
| --- | ---:| --- |
| Target frame rate | 25 fps | PMS 480p stream target |
| 480p coded geometry | 624×480 = 39×30 MBs = 1170 MB/frame | SPS/profile contract |
| `stream_path` clock | 20.000 MHz | `pll_0002.v` `outclk_0`; `Plex.sv` connects `stream_path.clk(clk_sys)` |
| SDRAM clock | selectable, default 100 MHz; `SDRAM_CLK_142` makes `clk_sdram` 142 MHz | `Plex.sv`/PLL |

The decode pipeline is clocked by `clk_sys`, not `clk_sdram`. Therefore the
480p realtime budget is:

```
1170 MB/frame × 25 fps = 29,250 MB/s
20,000,000 cycles/s ÷ 25 fps = 800,000 cycles/frame
800,000 cycles/frame ÷ 1170 MB/frame = 683.761 cycles/MB
```

## Raw measured cycle counts

Measured with Verilator 5.051 using the existing
`tests/unit/test_stream_path_full_frame_compare.sh` harness. The authoritative
cycle source is `build/p3_full_frame/frame_planes_compare.json` field
`summary.cycles`; this is full testbench time from reset/byte injection through
diagnostic frame output. It is not a native decode-quality metric and has no
stage breakdown. `build/p3_full_frame/native_frame_score.json` is the companion
quality scoreboard and has no cycle fields.

| Fixture | Frames | Geometry | Total cycles | cycles/frame | cycles/MB | Budget cycles/MB | Margin |
| --- | ---:| --- | ---:| ---:| ---:| ---:| ---:|
| `plex_inter_p16_baseline_320x240_12f.264` | 12 | 20×15 MB | 969,210 | 80,767.500 | 269.225 | 2,666.667 | 9.905× |
| `wcap_residual14_idr_plus_p.264` | 2 | 20×15 MB | 160,095 | 80,047.500 | 266.825 | 2,666.667 | 9.994× |
| `plex_inter_p16_baseline_624x480_12f.264` | 12 | 39×30 MB | 3,641,853 | 303,487.750 | 259.391 | 683.761 | 2.636× |

Additional raw integration signal:

| Harness | Raw signal | Value | Meaning |
| --- | --- | ---:| --- |
| `test_stream_path_deblock_integration.sh` on `wcap_residual14_idr_plus_p.264` | `recon_sig_3b_cycles` | 16,523 | deblock/stream integration liveness counter, not a per-stage cycle cost |
| `test_h264_multinal_stream_path.sh` 320×240 12f fixture | `recon_sig_3b_cycles` / `cycles` | 39,780 / 55,319 | P-slice DPB/MC liveness context from w-cabac; not full-frame P quality and not a stage cost |

## Stage coverage (per-stage cycle accounting, 2026-07-27)

The aggregate 259 cycles/MB was **98.7% decode_stub diagnostic paint overhead**.
Per-stage instrumentation (via `stub_busy`/`fs_wr_reset`/`fs_swap` phase
transitions in the Verilator testbench) reveals the true breakdown:

| Stage | cycles/MB | Status | Method |
| --- | ---:| --- | --- |
| parse_cavlc | 3.2 | **measured** | stub_busy rise → fs_wr_reset transition |
| dequant_idct | 0 | **measured** | combinational (h264_dequant4x4 + h264_idct4x4) |
| intra_pred | 0 | **measured** | combinational (DC pred=128 in h264_recon4x4) |
| diagnostic_paint | 256 | measured, **NOT PRODUCTION** | fs_wr_reset → fs_swap; WxH pixels at 1 px/cycle |
| mc_interpolation | **?** | **NOT IMPLEMENTED** | h264_inter_pred.sv is diagnostic-only |
| deblock | **?** | **NOT IMPLEMENTED** | h264_deblock.sv exists but not in pipeline |
| ddr_write | **?** | **NOT IMPLEMENTED** | ddr_frame_store not instrumented |
| injection_overhead | 10 | measured, **TESTBENCH ARTIFACT** | ioctl 2 cycles/byte; product uses DDR DMA |

**What "MARGINAL 2.64x" actually measured:** the ratio of the realtime budget
(684 cycles/MB) to the aggregate cycle count (259 cycles/MB), where the
aggregate is dominated by decode_stub painting 624×480 diagnostic pixels per
frame — an operation that does not exist in the production decoder. The three
most expensive production stages (MC, deblock, DDR write) contribute exactly
**zero measured cycles** because they are not built yet. The margin is
**illusory** and will collapse when those stages are implemented.

**Note on parse_cavlc timing:** the 3.2 cycles/MB figure includes P-frame
decode_stub WAIT_MAX timeout (4096 cycles each) because `residual_place_pulse`
does not fire for unimplemented inter frames. The IDR-only parse cost is
~0.25 cycles/MB (287 cycles for 1170 MBs). Once inter is implemented and
residual arrives for every frame, this number will change.

Do not use stale `build/p3_full_frame_624/native_score_624.json` artifacts if
present. The full-frame candidate stream is `I420_FROM_RGB565` diagnostic output;
the cycle number is useful, but its pixel quality is not native-I420 evidence.

## DDR bandwidth

The current DPB fetch/write shape on w-rel's branch issues:

- MC reference fetch: 441 luma + 81 U + 81 V = **603 reads/MB**.
- Filtered/current writeback: 256 luma + 64 U + 64 V = **384 writes/MB**.
- Total DPB traffic: **987 B/MB**.

At 29,250 MB/s:

```
987 B/MB × 29,250 MB/s = 28,869,750 B/s = 28.87 MB/s
```

The display frame store also consumes one 624×480 I420 frame per presented
frame:

```
624×480×1.5×25 = 11,232,000 B/s = 11.23 MB/s
```

The 624×480 12-frame fixture is 70,348 bytes, or 146,558 B/s at 25 fps. Even
doubling that for compressed bitstream write/read is less than 0.30 MB/s.

Known modelled traffic is therefore about **40.4 MB/s** before refresh/arbitration
losses. Raw bandwidth should be enough, but this is not a pass: the bitstream
reader, DPB, and frame store contend for the same `DDRAM_*` path, and the live
PLXF-missing fault means arbitration/liveness remains a first-class risk.

## Per-stage budget allocation (estimated, revised 2026-07-27)

**Owner: w-c1. Status: ESTIMATE — no unbuilt stage is measured.**

Total budget: **684 cycles/MB** at 20 MHz / 25 fps / 1170 MB per frame.

After 64-bit coalesced DPB traffic (~124 beats/MB for reference fetch + frame
write), approximately **560 cycles/MB** remain for computation.

| Stage | Allocated | Reasoning |
| --- | ---:| --- |
| parse_cavlc (full) | 50 | Current 3 cycles/MB is first-MB-only. Full MB parsing (mb_type, CBP, per-block CAVLC for 24 blocks I420, Intra_16x16 Plane, I_PCM) will be much higher. CAVLC is fundamentally serial. |
| dequant_idct | 48 | 24 blocks/MB at 2 cycles/block in a 2-stage pipeline. Currently combinational for single blocks; needs registered outputs for all-block throughput. |
| intra_pred | 30 | DC is trivial but directional modes need neighbor reads. Intra_16x16 Plane requires per-pixel MAC. I_PCM bypasses 384 bytes. |
| **mc_interpolation** | **250** | **DOMINANT COST.** 21×21 luma qpel window through 6-tap filter + DDR reference fetch (~100 beats with arbitration). Without adjacent-MB overlap exploitation: ~250. With overlap: ~150. Sub-MB partitions multiply fetch count. |
| **deblock** | **150** | **REVISED UP from 100.** 48 edge segments per MB (32 luma + 16 chroma). `h264_deblock_edge_pipe` is a 2-stage pipeline (register→filter→register), 4 samples/segment. Steady-state 1 segment/cycle → ~50 cycles for filtering alone. Scheduler SRAM overhead: each segment needs read p0-p3/q0-q3 (2 reads for 32-bit SRAM) + write-back modified samples. Single-port MB SRAM: 48 × (1 filter + 2 SRAM) ≈ 144. Vertical→horizontal data dependency forces pipeline drain between passes (+2). **Dual-port MB SRAM would drop this to ~100** — flag to w-a3. |
| ddr_write | 50 | 48 coalesced 64-bit beats + arbitration turnaround. |
| control_overhead | 30 | Pipeline stalls, MB-boundary bookkeeping, QP delta, slice header re-parse, arbitration bubbles. |
| **TOTAL** | **608** | |
| **Remaining margin** | **76** | 684 − 608 = 76 cycles/MB = **1.12× margin** |

### Adjacent-MB reference overlap (key to MC feasibility)

For P_L0_16x16 with similar MVs on horizontally adjacent MBs, the 21×21
reference window overlaps by ~16 columns. A line buffer can amortise this to
~40 fresh DDR reads/MB instead of ~100, saving ~60 cycles. **This is the
difference between MC being feasible and MC blowing the budget.** w-mc should
design the reference fetch with overlap exploitation from the start.

### What this excludes

- **Intra_16x16 Plane mode** (not implemented per w-cabac coverage audit, QP 5–27 only)
- **I_PCM** (not implemented in RTL)
- Arbitration contention from display reads (frame_store consumer)
- Content variation (high-motion P-frames with sub-MB partitions)
- w-a3's m1 response async FIFO latency (added at `3c6d1d2`)
- CABAC (not relevant — Baseline profile uses CAVLC only)

## Sensitivity analysis

The 1.12× margin rests on estimates for three unbuilt stages (MC 250 + deblock
150 + DDR write 50 = 450 cycles = 74% of the 608 total). This section states
the breaking points.

### MC breaking point

Non-MC stages sum to 358 cycles/MB. The budget breaks when MC exceeds:

```
684 − 358 = 326 cycles/MB    ← MC breaking point
```

The current MC estimate is 250. That is **76 cycles of headroom** — a 30%
overrun on a module that does not exist yet.

### 50% overrun on all unbuilt stages

| Stage | Base | +50% |
| --- | ---:| ---:|
| mc_interpolation | 250 | 375 |
| deblock | 150 | 225 |
| ddr_write | 50 | 75 |
| Subtotal unbuilt | 450 | 675 |
| + built stages | 158 | 158 |
| **Total** | **608** | **833** |
| vs 684 budget | 1.12× OK | **1.22× OVER — FAILS** |

At 50% overrun, the pipeline exceeds the budget by **149 cycles/MB** (22%).
This would require either a clock increase or architectural parallelism.

### Scenario table

| Scenario | MC | Deblock | Total | Margin | Verdict |
| --- | ---:| ---:| ---:| ---:| --- |
| Base estimate | 250 | 150 | 608 | 1.12× | TIGHT |
| MC with overlap exploit | 150 | 150 | 508 | 1.35× | FEASIBLE |
| MC with overlap + dual-port deblock | 150 | 100 | 458 | 1.49× | COMFORTABLE |
| MC no overlap, single-port deblock | 250 | 150 | 608 | 1.12× | TIGHT |
| MC overruns 30% | 325 | 150 | 683 | 1.00× | BREAK EVEN |
| MC overruns 50% | 375 | 150 | 733 | 0.93× | **FAILS** |
| All unbuilt +50% | 375 | 225 | 833 | 0.82× | **FAILS BADLY** |
| MC at 400 (complex content) | 400 | 150 | 758 | 0.90× | **FAILS** |

### What would save the budget

1. **Adjacent-MB overlap in MC** — saves ~100 cycles, moves from 1.12× to 1.35×
2. **Dual-port MB SRAM for deblock** — saves ~50 cycles, moves from 1.12× to 1.20×
3. **Both together** — 1.49× margin, which is the first scenario I would call "comfortable"
4. **Move decode to 90 MHz `clk_ddr`** — budget becomes 3,077 cycles/MB (4.5× the current), eliminates all timing risk but requires CDC on every decode↔system interface

### Honest assessment

The **base estimate (1.12×) is not a comfortable number**. Three of the four
largest stages are estimates for unbuilt FPGA modules. FPGA estimates are
usually optimistic: synthesis constraints, routing congestion, and arbitration
contention all add cycles that paper analysis misses.

**The budget probably works IF the two architectural optimisations land** (MC
overlap + dual-port deblock → 1.49×). Without them, a single stage overrunning
by 30% breaks the budget.

**If MC lands above 326 cycles/MB, 25 fps at 20 MHz is not achievable.** That
is the number w-mc should treat as a hard ceiling, not 250.

## End-to-end effective fps

`check_decode_throughput.py` now reports **effective_fps**: the frame rate the
simulation actually achieves, computed as `clock_hz × frames / cycles_total`.
This is an end-to-end measurement that includes all pipeline overhead, stalls,
contention, and stage handoff bubbles — it cannot be gamed by summing optimistic
per-stage estimates.

Current measured values (non-production — includes diagnostic paint, excludes
MC/deblock/DDR):

| Fixture | effective_fps | Target fps | Note |
| --- | ---:| ---:| --- |
| 624×480 12f | 65.9 | 25 | Inflated: workload is diagnostic paint, not production decode |
| 320×240 12f | 247.6 | 25 | Lower resolution, much more headroom |
| wcap residual14 2f | 249.9 | 25 | Same resolution as 320×240 |

**These numbers are currently meaningless as production metrics** because the
three most expensive stages are missing. When MC, deblock, and DDR write are
implemented, effective_fps will become the definitive throughput measurement —
it will automatically capture DDR arbitration contention, pipeline stalls, and
any overhead that per-stage accounting misses.

The ratchet enforces `min_effective_fps` as a hard floor. If a code change
degrades throughput, it will show up here before it shows up in per-stage
accounting.

## Verdict

**TIGHT — 1.12× margin, down from 1.23× after deblock revision.** The revised
estimate of 608 cycles/MB against the 684 budget is not comfortable:

- MC (250) + deblock (150) = 400 cycles = **66% of the total allocation**
- The MC breaking point is **326 cycles/MB** — a 30% overrun breaks the budget
- At 50% overrun on all unbuilt stages, the pipeline exceeds the budget by 22%
- The 76-cycle margin would be consumed by arbitration contention alone if the
  m0/m1 DDR arbiter introduces ≥1 stall cycle per MB

**The budget probably works with both architectural optimisations:**
1. Adjacent-MB overlap in MC (250 → 150, saving 100 cycles)
2. Dual-port MB SRAM for deblock (150 → 100, saving 50 cycles)

These together yield 1.49× margin — the first comfortable scenario.

**Without both, the honest answer is: marginal, and any single stage overrunning
30% triggers the architecture conversation** about moving decode stages to
`clk_ddr` (90 MHz) or re-deriving the PLL.

## Ratchet

`tools/check_decode_throughput.py` consumes the existing full-frame comparison
JSON and a `misterplex.decode_throughput_ratchet.v1` manifest. The full-frame
RTL gate now writes a separate report under `build/realtime_throughput/` for
known fixtures, copying run label, fixture source, and geometry into the JSON.
`tests/unit/test_decode_throughput_gate.sh` proves RED by lowering the cycle and
margin thresholds.
