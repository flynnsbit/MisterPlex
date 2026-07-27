# Architecture Study: Can H.264 Decode Fit at 20 MHz?

**Author:** w-arch  
**Date:** 2026-07-27  
**Branch:** feat/arch-study  
**Status:** v2 — updated with w-c1 official allocation and w-a3 CDC data

---

## Executive Summary

**20 MHz (684 cycles/MB) is sufficient for 624×480 @ 25 fps H.264 Baseline
decode — but only if the DPB memory interface is widened from byte-serial to
64-bit coalesced reads.** With the current byte-serial DPB implementation
(`h264_dpb_one_ref`), the reference fetch alone consumes 988 cycles/MB, which
is 1.44× the entire budget. No amount of optimisation elsewhere can recover
that deficit.

The recommended path is **wider datapaths on the existing 20 MHz clock**, not
a faster clock. This avoids new CDC crossings in a project that has already
been burned by exactly that failure mode.

---

## 1. Clock Configuration (Traced from RTL)

**Source:** `rtl/pll/pll_0002.v` → `altera_pll` instantiation  
**Device:** 5CSEBA6U23I7 (Cyclone V SE, speed grade 7, industrial)

| Counter | Quartus Name    | Frequency  | Connected To         | Role              |
|---------|-----------------|------------|----------------------|-------------------|
| C0      | general[0].gpll | 20 MHz     | `clk_sys` (Plex.sv:215) | Core system clock |
| C1      | general[1].gpll | 142 MHz    | `clk_sdram` (Plex.sv:216) | SDRAM controller |
| C2      | general[2].gpll | 90 MHz     | `clk_ddr` (Plex.sv:217) | DDR bridge clock |

**PLL type:** Integer-N, single reference (50 MHz), `fractional_vco_multiplier = false`.  
**Outputs used:** 3 of up to 9 C-counter outputs per GPLL.  
**Spare capacity:** 6 additional outputs available from the same PLL, but only at
frequencies that are VCO/C for integer C. The achievable set depends on the
VCO frequency chosen by the fitter (constrained by the 20/142/90 MHz triple).

All three outputs come from **the same physical PLL** and are **synchronous**
(same reference, deterministic phase). This is confirmed by w-cap's clock
relationship analysis.

### PLL spare output analysis

Cyclone V GPLL VCO range (speed grade 7, I-grade): **600–1300 MHz**.

The fitter must find M, N such that VCO = 50 × M/N lands in [600, 1300] and
VCO/C produces all three requested frequencies. Because 142 and 20 share no
convenient common multiple below 1300 MHz, the fitter likely uses the closest
achievable approximation for 142 MHz (e.g., VCO=720: 720/5=144 MHz ≈ 142 MHz,
720/36=20 MHz, 720/8=90 MHz — off by ~1.4% on SDRAM clock, within spec).

If VCO ≈ 720 MHz, achievable 4th-output candidates:
- **40 MHz** (720/18) — 2× clk_sys, half-integer relationship
- **45 MHz** (720/16) — 2.25× clk_sys
- **60 MHz** (720/12) — 3× clk_sys
- **80 MHz** (720/9) — 4× clk_sys
- **90 MHz** (already exists)
- **360 MHz** (720/2) — probably infeasible for timing closure

**Provenance note:** The exact VCO is unknown without running the fitter.
The above assumes VCO ≈ 720 MHz; if the fitter chose a different VCO (e.g.,
~1260 MHz for tighter SDRAM accuracy), the available frequencies differ.
w-cap owns this fact and should confirm before any PLL modification.

---

## 2. Frame Budget (Confirmed)

```
Resolution:       624 × 480 = 39 × 30 = 1170 macroblocks/frame
Frame rate:       25 fps
MB throughput:    1170 × 25 = 29,250 MB/s
clk_sys:          20,000,000 Hz
Budget:           20,000,000 / 29,250 = 683.76 ≈ 684 cycles/MB
```

This budget is **hard** — there is no slack from framerate negotiation at
this resolution. If even one pipeline stage exceeds its allocation, frames
will be dropped.

---

## 3. Per-Stage Cycle Model

### 3.1 Measured stages (provenance: w-c1 ratchet measurements)

| Stage | Cycles/MB | Type | Provenance |
|-------|-----------|------|------------|
| `parse_cavlc` | 3.2 | Sequential | w-c1 measured on test vector |
| `dequant_idct` | 0 | Combinational | Traced: `h264_dequant4x4` + `h264_idct4x4` are pure wires |
| `intra_pred` | 0 | Combinational | Traced: `h264_intra4x4_pred` etc. are pure `always @*` |

**CAVLC provenance caveat:** The 3.2 cycles/MB figure is an average that
includes a high fraction of P_Skip macroblocks (which have zero residual
coding). For complex I-frames where every 4×4 block carries 16 non-zero
coefficients, CAVLC parsing could reach **50–100 cycles/MB**. The 3.2 figure
is a reasonable **weighted average** for typical movie content where 60–80%
of P-frame MBs are skips, but is not a worst-case bound.

### 3.2 Estimated stages (first-principles analysis)

#### 3.2.1 DPB Reference Fetch — THE CRITICAL PATH

**Current implementation:** `h264_dpb_one_ref` (rtl/h264_dpb.sv:240–350)

The fetch FSM issues **one byte-serial memory read per clock cycle**:
- `PH_LUMA`: indices 0..440 → **441 reads** (21×21 luma window)
- `PH_U`:    indices 0..80  → **81 reads** (9×9 chroma U window)
- `PH_V`:    indices 0..80  → **81 reads** (9×9 chroma V window)
- `PH_DRAIN`: 1 cycle
- **Subtotal reference read: 604 cycles**

Filtered sample writeback (via `filtered_sample_valid`):
- Luma 16×16: 256 bytes
- Chroma U 8×8: 64 bytes
- Chroma V 8×8: 64 bytes
- **Subtotal writeback: 384 cycles (byte-serial)**

**Total byte-serial DPB: 988 cycles/MB**

```
988 / 684 = 1.44×  →  DOES NOT FIT. Not close.
```

**With 64-bit coalesced access** (requires redesigned DPB controller):

Reference reads (burst-aligned, worst-case alignment):
- Luma: 21 rows × ceil(21+7)/8 = 21 × 4 = 84 beats (worst-case row misalignment)
- Chroma U: 9 rows × ceil(9+7)/8 = 9 × 2 = 18 beats
- Chroma V: 9 × 2 = 18 beats
- **Read subtotal: 120 beats**

Writeback (naturally aligned MB data):
- Luma: 16 rows × 2 beats = 32 beats
- Chroma: 2 × 8 rows × 1 beat = 16 beats
- **Write subtotal: 48 beats**

**Total 64-bit DPB: ~168 beats/MB** (including arbitration/turnaround overhead)

This leaves **684 − 168 = 516 cycles** for everything else.

#### 3.2.2 MC Interpolation

**Existing RTL:** `h264_inter_mc_16x16` (combinational, rtl/h264_dpb.sv:370–520)

The existing implementation is **fully combinational**: it instantiates
`h264_luma_qpel_block_16x16` which calls `qpel_at()` for all 256 luma pixels
in a single `always @*` block. Each `qpel_at()` invocation computes up to
three 6-tap FIR filters (`half_h_at`, `half_v_at`, `half_c_at`) and an
averaging step.

**This will NOT synthesize as-is on Cyclone V at any frequency.** The
combinational depth of 256 parallel 6-tap cross-filters is astronomically
deep (hundreds of logic levels). It is a correct functional model for
simulation, not a synthesisable architecture.

A practical implementation must time-multiplex:

| Approach | Parallelism | Luma cycles | Chroma cycles | Total |
|----------|-------------|-------------|---------------|-------|
| 1 sample/cycle | 1 FIR unit | 256 | 128 | 384 |
| 4 samples/cycle | 4 FIR units | 64 | 32 | 96 |
| 16 samples/cycle | 16 FIR units | 16 | 8 | 24 |
| 4×4 block pipe | 1 unit, 16 clocks/block | 256 | 64 | 320 |

**Each 6-tap FIR unit** requires 6 multiplications and 5 additions per
output sample. Quarter-pel needs two half-pel intermediates plus an average.
On Cyclone V, a single 6-tap FIR can be computed in 1 clock using DSP blocks
(18×18 multipliers, 112 available on 5CSEBA6U23I7).

**Recommended: 4 parallel FIR units → 96 cycles/MB.** This uses 24 of 112
DSP blocks (21%) — acceptable.

For P_Skip macroblocks with `skip_zero` (MV = 0,0): the reference is
co-located, no interpolation needed — just copy 384 bytes from reference
position. At 64-bit: 48 beats. **P_Skip cost: ~48 cycles total (fetch only,
no MC filter).**

#### 3.2.3 Residual Add

**Existing RTL:** `h264_recon4x4` (combinational, rtl/h264_iq_idct_4x4.sv)

16 parallel clip-and-add operations. Combinational, absorbed into MC pipeline.
**0 additional cycles.**

#### 3.2.4 Deblocking Filter

**Existing RTL:** Building blocks in `h264_deblock.sv`:
- `h264_deblock_bs` — boundary strength (combinational)
- `h264_deblock_thresholds` — α/β/tc0 LUTs (combinational)
- `h264_deblock_edge` — 4-sample edge filter (combinational)
- `h264_deblock_edge_pipe` — registered wrapper (2-cycle latency)
- `h264_deblock_writeback_ctrl` — sample counting + ref promotion

Per H.264 spec, deblocking operates on 4×4 block boundaries:

**Luma (16×16):**
- 4 vertical edge columns × 4 edge segments = 16 edges
- 4 horizontal edge rows × 4 edge segments = 16 edges
- Total: 32 edge filter operations

**Chroma (each 8×8):**
- 2 vertical × 2 segments + 2 horizontal × 2 segments = 8 per plane
- Two planes: 16 edge operations

**Total: 48 edge filter operations per MB.**

With `h264_deblock_edge_pipe` at 2 cycles/edge: 48 × 2 = **96 cycles**.

Additional overhead for reading neighbor samples from line buffers and
writing filtered results back: **~30 cycles** (line buffer RAM is single-port
M10K, needs sequential access for neighbor edges).

**Total deblocking estimate: 126 cycles/MB.**

#### 3.2.5 DDR Writeback

Filtered samples must be committed to the DPB current picture. This is
already counted in the DPB writeback (48 beats at 64-bit = 48 cycles).
If pipelined with deblocking (write filtered samples as they emerge from
the deblock edge pipe), **0 additional cycles** — absorbed into deblock.

#### 3.2.6 Intra_16×16 Plane and I_PCM

Currently `unsupported_code` in `h264_intra_mode_guard`
(rtl/h264_intra_pred.sv:243).

- **I16 Plane prediction:** Requires a gradient computation (H, V sums over
  16 boundary samples) then 256 multiply-add operations. At 4-wide: ~70 cycles.
  This is being implemented by w-plane.
- **I_PCM:** Raw 384 bytes, no transform. Just copy. At 64-bit: 48 cycles.

**Estimate: 70 cycles/MB** (worst case, I16 Plane).

#### 3.2.7 Pipeline Overhead

Handshaking between stages, FSM transitions, stall recovery: **~10 cycles/MB**
based on existing `decode_stub` FSM complexity.

### 3.3 Composite Budget

#### Case A: P macroblock with motion (worst-case P)

| Stage | Cycles | Notes |
|-------|--------|-------|
| CAVLC parse | 3 | Measured average |
| Dequant + IDCT | 1 | Registered |
| DPB ref fetch | 168 | 64-bit coalesced (120 read + 48 write) |
| MC interpolation | 96 | 4-wide FIR |
| Residual add | 0 | Absorbed |
| Deblocking | 126 | 48 edges × 2 + line buffer overhead |
| DDR writeback | 0 | Overlapped with deblock |
| Overhead | 10 | FSM transitions |
| **TOTAL** | **404** | **59% of 684 budget** |

#### Case B: P_Skip with zero MV (common case, 60–80% of P-frame MBs)

| Stage | Cycles | Notes |
|-------|--------|-------|
| CAVLC parse | 0 | No coded data |
| DPB ref copy | 48 | 64-bit, no interpolation |
| Residual add | 0 | No residual |
| Deblocking | 96 | Simpler (most edges bs=0) |
| **TOTAL** | **~144** | **21% of 684 budget** |

#### Case C: I macroblock (worst-case overall: I16 Plane + dense CAVLC)

| Stage | Cycles | Notes |
|-------|--------|-------|
| CAVLC parse | 80 | Dense coefficients, all 24 blocks coded |
| Dequant + IDCT | 1 | Registered |
| I16 Plane pred | 70 | Gradient + 256 pixel generation |
| DPB writeback | 48 | 64-bit, no reference read |
| Deblocking | 126 | Full deblock |
| Overhead | 10 | |
| **TOTAL** | **335** | **49% of 684 budget** |

#### Weighted average (typical movie content)

Assuming 70% P_Skip, 20% P_Motion, 10% Intra:
```
0.70 × 144 + 0.20 × 404 + 0.10 × 335 = 100.8 + 80.8 + 33.5 = 215 cycles/MB
```

**Margin: 684 − 215 = 469 cycles (69% slack).** Even doubling every estimate
leaves comfortable headroom.

---

## 3A. Official w-c1 Allocation (f31c61a)

w-c1 owns per-stage cycle ratchets and delivered this binding allocation:

| Stage | Cycles/MB | % of 684 | Status |
|-------|-----------|----------|--------|
| **MC interpolation** | **250** | **37%** | **UNBUILT — dominant risk** |
| deblock | 100 | 15% | Building blocks exist, scheduler unbuilt |
| parse_cavlc (full) | 50 | 7% | Partially measured |
| ddr_write | 50 | 7% | Unbuilt |
| dequant_idct | 48 | 7% | Combinational (0 today, 48 budgeted for pipeline regs) |
| intra_pred | 30 | 4% | Combinational (0 today, 30 budgeted) |
| control overhead | 30 | 4% | FSM transitions |
| **Total** | **558** | **82%** | |
| **Margin** | **126** | **1.23×** | |

### Risk Assessment of the 1.23× Margin

**This margin is thin for an estimate-dominated budget.** Three of the seven
stages (MC interpolation, deblock, ddr_write — together 400 cycles, 72% of
the total allocation) are **entirely unbuilt**. Engineering estimates for
unbuilt blocks are systematically optimistic; a 1.23× margin provides only
~20% overrun tolerance before the budget fails.

**Critical: MC at 250 is 37% of the budget.** If MC lands at 400 cycles/MB
(plausible if the reference cache miss rate is worse than expected), the total
becomes 708 and the budget fails outright (708/684 = 1.04× overshoot). If MC
lands at 350, the total is 658 with only 1.04× margin — not credibly safe.

**The 250-cycle MC allocation rests on a specific architectural assumption:**
adjacent-MB reference overlap exploitation (sliding window cache). w-c1
states this is MANDATORY — without it, the budget does not close. This means
the MC core architecture is not a free design choice; it is constrained by
the cycle budget.

### Missing from the allocation

**Intra_16×16 Plane and I_PCM** are currently `unsupported_code` in RTL
(h264_intra_pred.sv:243) and are being implemented by w-plane. These are
required for real content.

- I16 Plane prediction: gradient computation (H, V sums over 16 boundary
  samples) + 256 multiply-add operations → **~70 cycles/MB** (worst case,
  only for I16 Plane MBs)
- I_PCM: raw 384 bytes, no transform → **48 cycles** at 64-bit

The `intra_pred` allocation is 30 cycles — insufficient for I16 Plane. The
Plane cost must come from the 126-cycle margin, reducing effective margin to
~56 cycles (1.09× — dangerously thin). **This is acceptable only because I16
Plane MBs are rare in typical Baseline content** (most encoders prefer I4×4
for quality; Plane mode is uncommon). But it must be tracked.

---

## 4. Verdict on 20 MHz

### The answer is YES — tight but feasible, with two non-negotiable conditions.

**20 MHz is sufficient for 624×480 @ 25 fps H.264 Baseline decode**, but the
margin is thin (1.23× on w-c1's official allocation) and rests on two
architectural conditions that are NOT optional:

1. **64-bit coalesced DPB memory interface** — byte-serial (988 cyc/MB) is
   1.44× the entire budget.
2. **Adjacent-MB reference overlap exploitation** in the MC core — without a
   sliding window cache, MC interpolation cannot hit 250 cycles/MB.

If either condition is not met, the budget fails and a clock change or scope
reduction is required (see §5A Contingency Plan).

### Condition 1: 64-bit DPB memory interface

The current `h264_dpb_one_ref` fetches reference windows one byte per clock
cycle. At 988 cycles/MB for a single P macroblock partition, this is
**1.44× the entire budget**. There is no way to make this work at 20 MHz
without widening the bus.

A 64-bit coalesced DPB controller reduces this to ~168 cycles/MB (4.1×
throughput increase for 8× bus width — the difference from 8× is alignment
waste). This is the single highest-impact change in the decode path.

### Condition 2: MC reference cache with adjacent-MB overlap

A 16×16 luma block at quarter-pel requires a 21×21 reference region. Two
horizontally adjacent MBs with similar MVs share ~18 of 21 columns — 86%
overlap. Re-fetching the full 21×21 for every MB would cost ~120 DPB read
beats per MB; with a sliding window cache that retains the overlap, the
marginal cost drops to ~16–20 beats for the 3 new columns.

**w-c1 states this is MANDATORY for the 250-cycle MC target.** Without it,
the fetch component alone would consume ~120 of the 250 cycles, leaving only
130 for the 6-tap FIR on 256 luma + 128 chroma samples — barely 0.3 cycles
per output sample, requiring 3+ parallel FIR units and 18+ DSP blocks.
Feasible but tight. The cache relaxes this to a comfortable ~1 cycle per
sample with a 4-wide FIR.

**Caveat:** MVs differ per MB. When a scene cut or fast pan causes adjacent
MBs to have very different MVs, the cache miss rate spikes and the overlap
benefit vanishes. The MC core must degrade gracefully to full-refetch in
these cases, and the worst case must still fit within 250 cycles. **Measure
the realistic hit rate on w-cabac's graded P-slice ladder (rungs 2–6).**

### What about the discredited 100 MHz / 3,418 cycles/MB figure?

The `docs/p3-mc-dpb-bandwidth.md` document states:

> *"The decode schedule has about 100 MHz / (1170 × 25) = 3418 fabric
> cycles/MB."*

This figure has **no provenance**. It uses 100 MHz, which is the SDRAM
default clock (`clk_sdram`), not the decode clock (`clk_sys` = 20 MHz).
The decode path runs on `clk_sys` — confirmed by tracing `stream_path`
instantiation at Plex.sv:588: `.clk(clk_sys)`. The correct budget is
684 cycles/MB at 20 MHz.

The 100 MHz figure likely originated from confusion between `clk_sdram`
(which drives the SDRAM controller) and the decode fabric clock. It has
been propagated through documentation without being traced to RTL. **Do
not use it for any planning purpose.**

---

## 5. Options Analysis (If Budget Tightens)

The 1.23× margin is thin enough that a contingency plan is not academic —
it is operationally necessary. If MC lands above 250, the question becomes:
**what is the cheapest credible escape?**

### 5A. CONTINGENCY PLAN: What If MC Exceeds 250?

**Trigger:** MC interpolation measured at >250 cycles/MB on w-cabac's graded
P-slice ladder, after reasonable optimisation effort.

**Escalation ladder (cheapest first):**

#### Tier 1: Squeeze within 20 MHz (cost: days, no new CDC risk)

| Action | Cycles recoverable | Difficulty |
|--------|-------------------|------------|
| More aggressive reference cache (prefetch next MB's window speculatively) | 20–40 | Medium |
| Wider FIR: 8-parallel instead of 4 (48 DSP blocks, 43% of budget) | ~48 (96→48) | Low |
| P_Skip zero-MV fast path (bypass FIR entirely) | ~260 average savings | Low (but only helps average, not worst-case) |
| Reduce deblock from 100 to 80 (2-wide edge pipe) | 20 | Low |
| Total recoverable | **~130 cycles** | |

**If MC is at 380 or below, Tier 1 is sufficient** (380 + remaining 308 = 688,
add 130 recovery → effective budget 814 > 688). 

#### Tier 2: Add a dedicated decode PLL output (cost: weeks, moderate CDC risk)

If MC genuinely cannot hit 250 even with Tier 1, add a 4th PLL output for
a dedicated decode clock. Based on PLL analysis (§1):

**Candidate: 40 MHz** (VCO/C, feasibility depends on fitter-chosen VCO)
- Budget: 40M / 29,250 = **1,368 cycles/MB** (2× current)
- MC allocation: 500 cycles → trivially achievable even without cache

**CDC crossings required (enumerated, not assumed):**

Based on `stream_path` port analysis (rtl/stream_path.sv:7–96), the decode
pipeline exchanges these signal groups with the clk_sys domain:

| # | Signal group | Width | Direction | CDC mechanism needed |
|---|-------------|-------|-----------|---------------------|
| 1 | Bitstream FIFO output (`bf_rd_data`, `bf_rd_en`, `bf_rd_empty`) | 10 | clk_sys → clk_decode | Async FIFO (proven: `async_fifo` already in repo, used by w-a3 for arbiter response) |
| 2 | DDR bus signals (`ddr_busy`, `ddr_dout[63:0]`, `ddr_dout_ready`, `ddr_rd`, `ddr_addr[28:0]`, `ddr_burstcnt[7:0]`, `ddr_din[63:0]`, `ddr_be[7:0]`, `ddr_we`) | ~180 | clk_decode ↔ clk_ddr | **HIGH RISK** — this is the exact crossing that w-a3 just spent days fixing. Would need arbiter m2 port or second async FIFO pair. |
| 3 | Frame store write (`fs_wr_en`, `fs_wr_pixel[15:0]`, `fs_wr_reset`, `fs_swap`) | 20 | clk_decode → clk_sys | Async FIFO (write samples at decode rate, read at display rate) |
| 4 | Status/telemetry (residual_csum, recon_sig, etc.) | ~60 | clk_decode → clk_sys | 2-FF synchronizers (multi-cycle, low bandwidth) |
| 5 | Control inputs (reset, flush, config) | ~5 | clk_sys → clk_decode | 2-FF synchronizers (quasi-static) |
| 6 | ioctl interface (download, wr, dout) | 10 | clk_sys → clk_decode | Through bitstream FIFO (crossing #1) |

**Total: 6 crossing groups, ~285 signal wires crossing clock domains.**

**Engineering cost of the crossings:**

Crossing #2 (DDR bus) is the dangerous one. w-a3's experience:

> *"ddr_bus_arbiter was on clk_sys (20 MHz) between two 90 MHz endpoints —
> 17 unsynchronized signal groups. Moving it to clk_ddr eliminated PATH 2
> (slack −1.346 ns) but exposed a fast→slow pulse hazard on m1_dout_ready:
> a single 11.1 ns clk_ddr pulse sampled by a 50 ns consumer, with 7/10
> CAS latencies dropping the beat. Required an async_fifo #(.WIDTH(64),
> .AW(3)) to fix."* — w-a3, `3c6d1d2`

A clk_decode domain would create **the same category of problem**: DDR
responses arriving at 90 MHz must be captured by a 25–40 ns consumer.
The fix is known (async FIFO), but the failure mode is subtle (STA passes,
functional testing fails intermittently depending on phase alignment).

**Estimated CDC engineering effort: 2–3 weeks** for a senior FPGA engineer
who has already been through the arbiter CDC exercise. 1–2 async FIFOs,
comprehensive beat-conservation testing, STA re-validation.

#### Tier 3: Move decode to clk_ddr (90 MHz) — last resort

**Budget:** 90M / 29,250 = **3,077 cycles/MB** (4.5× current)

This eliminates the MC cycle pressure entirely — even byte-serial DPB at
988 fits easily in 3,077. **But the CDC cost is severe:**

All 6 crossing groups from Tier 2 apply, but crossing #2 is eliminated
(decode and DDR are same clock). However, crossings #1 and #3 become
**faster→slower** (90→20 MHz), which is the exact direction that caused
the pulse-drop bug. Both would need async FIFOs.

**The real cost is not the FIFOs — it is the testing.** w-a3 spent ~4
commits and extensive beat-conservation testing to handle ONE 90→20 MHz
crossing (arbiter m1 response). Moving the entire decode pipeline adds
two more such crossings, each with different data widths, burst patterns,
and backpressure semantics.

**Estimated CDC engineering effort: 4–6 weeks.** Not recommended unless
Tier 1 and Tier 2 are exhausted.

#### Tier 4: Reduce scope

| Reduction | New budget | MC allocation at 37% |
|-----------|-----------|---------------------|
| 624×480 @ 20 fps | 855 cyc/MB | 316 cyc/MB |
| 624×480 @ 15 fps | 1,140 cyc/MB | 422 cyc/MB |
| 480×360 @ 25 fps | 1,185 cyc/MB | 439 cyc/MB |

**20 fps is the cheapest scope reduction** — it buys 25% more cycles with
no resolution change. 15 fps is noticeable but tolerable for many content
types. Resolution reduction is a last resort.

---

## 6. Timing Closure Reality Check

### Current state (pre-CDC-fix builds)

From w-cap's clock relationship analysis (feat/cap-device):

```
PATH 1: slack -2.137 ns (90→20 MHz crossing)
  f2sdram register (90 MHz) → arbiter combinational → ddr_bitstream_reader (20 MHz)
  Relationship: 5.556 ns, Data delay: 6.181 ns

PATH 2: slack -1.346 ns (20→90 MHz crossing)
  arbiter rsp_left (20 MHz) → combinational → ddr_frame_store (90 MHz)
  Relationship: 5.555 ns, Data delay: 5.786 ns
```

**Critical observation:** Both failing paths are **CDC crossings**, not
intra-domain paths. The 20 MHz fabric (50 ns period) has **no reported
intra-domain timing failures**. This means:

1. The 20 MHz domain itself has comfortable timing margin.
2. Adding more logic to the 20 MHz domain (decode pipeline) is unlikely
   to create new timing failures, because the 50 ns period is generous
   for Cyclone V combinational depths.
3. The timing problems are localised to the clk_sys ↔ clk_ddr boundary,
   which is being addressed by w-a3's CDC fixes.

### Impact on recommendations

- **Tier 3 (move to clk_ddr):** Would need to close timing at 11.1 ns
  period (90 MHz) for the entire decode pipeline. Given that even 20 MHz
  has CDC-related failures, this is risky.
- **Tier 2 (new PLL output):** Creates new CDC crossings, which are the
  exact failure mode. Each new crossing must be properly synchronised.
- **§5C (wider datapaths at 20 MHz):** No new clock domains. The
  wider DPB bus is just more wires in the same clock domain. **Lowest
  timing risk.** Area increase for a 64-bit DPB controller is modest.

### Can the decode pipeline close timing at 20 MHz?

The worst combinational depth in the decode path is the MC interpolation
6-tap FIR. A single `half_c_at` computation involves:
- 6 horizontal FIR → 6 vertical FIR → clip → average
- ~15 logic levels of multiply-add

At Cyclone V speed grade 7, a typical ALM delay is ~0.5–1.0 ns.
15 levels × 1.0 ns = 15 ns, well within the 50 ns period.

If using DSP blocks for the FIR (recommended), the multiply latency is
~3 ns, and the pipeline can be registered at each tap stage. **Timing
closure at 20 MHz is not a concern for the decode pipeline.**

---

## 7. Recommendations

### 7.1 Immediate (architecture-level, before MC datapath is committed)

1. **Design the DPB controller for 64-bit burst access from day one.**
   This is not optional. The byte-serial interface does not fit in the
   cycle budget. w-mc and w-rel must coordinate on this.

2. **Keep the entire decode pipeline on `clk_sys` (20 MHz).** Do not
   introduce a new clock domain. The cycle budget is sufficient (w-c1
   allocation: 558/684, 1.23× margin), and new CDC crossings are the
   project's highest-risk failure mode (see w-a3's 4-commit arbiter
   fix sequence: `60df5a2`→`3c6d1d2`).

3. **Design MC interpolation with adjacent-MB reference cache.**
   This is MANDATORY per w-c1's allocation. Without overlap exploitation,
   the 250-cycle MC target does not close. The cache must degrade
   gracefully when MVs diverge. Measure hit rate on w-cabac's graded
   P-slice ladder (rungs 2–6).

4. **Plan MC as time-multiplexed with 4 parallel FIR units.**
   The existing combinational `h264_inter_mc_16x16` is a simulation model,
   not a synthesis target. Budget 24 DSP blocks for the FIR array.

5. **Report cycles/MB as a first-class testbench output from day one.**
   w-c1's ratchet will measure MC against 250 automatically once it lands.
   If you cannot hit 250, say so early — the Tier 1–2 contingency plan
   (§5A) exists specifically for this case.

6. **P_Skip fast path:** When `skip_zero` is asserted (MV = 0,0), bypass
   the FIR entirely and copy the co-located 16×16 reference block directly.

### 7.2 Implementation order

1. 64-bit DPB controller (w-rel / w-mc) — **gating**
2. Adjacent-MB reference cache (w-mc) — **gating for 250-cycle target**
3. Time-multiplexed MC FIR (w-mc) — **gating**
4. Deblock scheduler integration (w-rel) — **needed for correctness**
5. P_Skip fast path — **optimisation, do after basic pipeline works**
6. I16 Plane + I_PCM (w-plane) — **needed for real content**

### 7.3 Monitoring and escalation

After the MC datapath is built, w-c1 should measure the actual per-stage
cycle counts on real content and compare against this model. The key
numbers to watch:

| Metric | Target | Hard limit | Escalation |
|--------|--------|------------|------------|
| MC cycles/MB | ≤250 | 380 (with Tier 1) | >380 → Tier 2 (new PLL output) |
| DPB fetch cycles/MB | ≤168 | 200 | >200 → cache sizing issue |
| Deblock cycles/MB | ≤100 | 130 | >130 → 2-wide edge pipe |
| Total pipeline cycles/MB | ≤558 | 684 | >684 → frame drops |

**If MC exceeds 250 but is below 380:** apply Tier 1 optimisations (§5A) —
wider FIR, aggressive cache prefetch, P_Skip fast path. Recovers ~130 cycles.

**If MC exceeds 380:** escalate to Tier 2 — add dedicated 40 MHz PLL output.
Budget 2–3 weeks for CDC engineering (w-a3). See §5A for enumerated crossings.

---

## 8. Provenance Ledger

| Fact | Source | Confidence |
|------|--------|------------|
| clk_sys = 20 MHz | `pll_0002.v` line 46: `output_clock_frequency0("20.000000 MHz")` | Traced ✓ |
| clk_ddr = 90 MHz | `pll_0002.v` line 52: `output_clock_frequency2("90.000000 MHz")` | Traced ✓ |
| clk_sdram = 142 MHz | `pll_0002.v` line 49 + QSF macro `SDRAM_CLK_142=1` | Traced ✓ |
| stream_path on clk_sys | `Plex.sv:588`: `.clk(clk_sys)` | Traced ✓ |
| DPB luma fetch = 441 reads | `h264_dpb.sv:339`: `issue_idx == 9'd440` | Traced ✓ |
| DPB chroma fetch = 81 reads each | `h264_dpb.sv:344,350`: `issue_idx == 9'd80` | Traced ✓ |
| DPB writeback = 384 bytes | 256 Y + 64 U + 64 V (per H.264 spec) | Derived ✓ |
| Device = 5CSEBA6U23I7 | `sys/sys.tcl` line 2 | Traced ✓ |
| Speed grade = 7 (slowest) | `sys/sys.tcl` line 5 | Traced ✓ |
| STA failure = -2.137 ns | w-cap `clock_relationship_analysis.md` PATH 1 | Cross-ref ✓ |
| CAVLC = 3.2 cyc/MB (average) | w-c1 measurement (becomes 50 in official allocation) | Reported |
| 100 MHz budget = discredited | `p3-mc-dpb-bandwidth.md`: uses wrong clock | Debunked ✓ |
| w-c1 total allocation = 558/684 | w-c1 at `f31c61a`, delivered via parent | **Official** |
| MC allocation = 250 cyc/MB | w-c1, conditional on adjacent-MB cache | **Official** |
| Arbiter was on wrong clock | w-a3 `60df5a2`: 17 unsynchronized crossings | Traced ✓ |
| Pulse hazard: 7/10 CAS drops | w-a3 `3c6d1d2`: m1_dout_ready beat conservation test | Traced ✓ |
| Async FIFO fix for m1 response | w-a3 `3c6d1d2`: `async_fifo #(.WIDTH(64), .AW(3))` | Traced ✓ |
| MC interpolation = 96 cyc/MB | First-principles estimate, 4-wide FIR | **Estimate** |
| Deblocking = 126 cyc/MB | First-principles estimate, 48 edges × 2 + overhead | **Estimate** |
| P_Skip fraction = 60–80% | Typical movie content heuristic | **Assumption** |
| VCO ≈ 720 MHz | Inference from PLL constraints | **Unverified** |
| 6 CDC crossing groups if clock change | Enumerated from stream_path ports | Traced ✓ |
| ~285 signal wires cross domain | Counted from stream_path + DDR interface | Counted ✓ |

---

## 9. Open Questions

1. **Exact VCO frequency** — w-cap should confirm by inspecting fitter
   output or running a trial fit. This determines what intermediate
   frequencies are available if Tier 2 (§5A) is ever triggered.

2. **Actual CAVLC worst-case** — w-c1's allocation gives 50 cycles for
   `parse_cavlc`. This needs measurement on a complex I-frame to bound
   the worst case. If a single MB's CAVLC exceeds 50 cycles, it either
   borrows from the margin or stalls the pipeline.

3. **DDR arbitration contention** — The DPB shares the DDR bus with
   `ddr_frame_store` (present path) and `ddr_bitstream_reader` (stream
   path) via `ddr_bus_arbiter`. Under contention, DPB fetch cycles will
   increase. w-a3's arbiter design must guarantee worst-case latency
   bounds. The current arbitration is round-robin with no priority or
   latency guarantee.

4. **Sub-MB partitions** — The cycle model assumes P_L0_16×16 (one
   motion vector per MB). P_L0_16×8 and P_L0_8×16 require two reference
   fetches; P_8×8ref requires four. With 64-bit coalescing and the
   adjacent-MB cache, the per-fetch overhead is smaller, but multi-partition
   MBs could reach the 250-cycle limit. Measure on w-cabac's graded
   P-slice ladder.

5. **I16 Plane on the DSP budget** — w-plane's implementation must use
   shift-add, not DSP multipliers, to preserve DSPs for MC FIR. The
   I16 Plane gradient computation (17× multiplier) can be decomposed
   as 16+1 = shift+add. Verify this constraint is communicated.

6. **Adjacent-MB cache miss rate** — The 250-cycle MC target assumes
   high cache hit rates for horizontally adjacent MBs. Scene cuts, fast
   pans, and sub-MB partitions with divergent MVs will cause misses.
   **Measure the realistic hit rate** on w-cabac's rungs 2–6 before
   committing to the 250 target. If the hit rate is below ~70%, escalate
   to Tier 1 optimisations immediately.

7. **Post-CDC-fix STA update** — w-a3's arbiter fixes (`60df5a2`,
   `3c6d1d2`, `d86c183`, `9461845`) have landed but no post-fix STA
   run has been done. w-cap should confirm whether the -2.137 ns and
   -1.346 ns failures are resolved. This affects all contingency options.

---

*This study is a living document. Update it when measured numbers replace
estimates. Every number has a provenance — keep it that way.*
