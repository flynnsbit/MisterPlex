# Architecture Study: Can H.264 Decode Fit at 20 MHz?

**Author:** w-arch  
**Date:** 2026-07-27  
**Branch:** feat/arch-study  
**Status:** ANALYSIS COMPLETE — verdict: **20 MHz is sufficient, conditionally**

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

## 4. Verdict on 20 MHz

### The answer is YES — with one non-negotiable condition.

**20 MHz is sufficient for 624×480 @ 25 fps H.264 Baseline decode**, provided
the DPB memory interface is upgraded from byte-serial to **64-bit coalesced
burst access**. The composite cycle budget uses at most 59% of the 684-cycle
allocation in the worst non-skip case, leaving 41% margin for implementation
overhead, stalls, and arbitration contention.

### The condition: 64-bit DPB memory interface

The current `h264_dpb_one_ref` fetches reference windows one byte per clock
cycle. At 988 cycles/MB for a single P macroblock partition, this is
**1.44× the entire budget**. There is no way to make this work at 20 MHz
without widening the bus.

A 64-bit coalesced DPB controller reduces this to ~168 cycles/MB (4.1×
throughput increase for 8× bus width — the difference from 8× is alignment
waste). This is the single highest-impact change in the decode path.

**w-mc and w-rel: the DPB controller width is an architecture-level
requirement, not an optimisation.** It must be designed for 64-bit from the
start.

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

Even though 20 MHz appears sufficient, this section evaluates fallback
options in case implementation realities (arbitration contention, deeper
pipeline stalls, sub-MB partition handling) consume the margin.

### Option A: Move decode to `clk_ddr` (90 MHz)

**Budget:** 90,000,000 / 29,250 = **3,077 cycles/MB** (4.5× current)

**Pros:** Massive headroom. Even byte-serial DPB (988 cycles) fits easily.
No need to redesign the DPB controller.

**Cons — CDC crossings that would be required:**

| Crossing | From → To | Signals | Risk |
|----------|-----------|---------|------|
| 1. Bitstream input | clk_sys → clk_decode | `ioctl_wr`, `ioctl_dout`, FIFO output | Medium (FIFO-based, well-understood) |
| 2. DPB ↔ DDR | clk_decode ↔ clk_ddr | `DDRAM_*` bus (already failing STA) | **HIGH** — exact failure mode that caused -2.137 ns slack |
| 3. Reconstructed frame output | clk_decode → clk_sys | Frame store write port, swap signals | Medium |
| 4. Status/telemetry | clk_decode → clk_sys | residual_csum, recon_sig, etc. | Low (can be multi-cycle) |
| 5. Control signals | clk_sys → clk_decode | reset, flush, config registers | Low (quasi-static) |

**The project was just burned by crossing #2.** PATH 1 in w-cap's analysis
is exactly this interface: f2sdram (90 MHz) → ddr_bus_arbiter (20 MHz) →
stream_path registers (20 MHz), failing at -2.137 ns. Moving decode to a
different clock makes this problem WORSE, not better, because it adds a
third clock domain to an already-broken two-domain crossing.

**Verdict: NOT RECOMMENDED.** The CDC risk is too high for a project at
this stage, and the budget analysis shows it is not needed.

### Option B: New PLL output (dedicated decode clock)

**Candidate frequencies** (from same PLL, VCO assumed ~720 MHz):

| Freq | Budget (cyc/MB) | Margin vs worst P | CDC crossings |
|------|-----------------|-------------------|---------------|
| 40 MHz | 1,368 | 3.4× | 2 new (bitstream in, frame out) |
| 45 MHz | 1,538 | 3.8× | 2 new |
| 60 MHz | 2,051 | 5.1× | 2 new |

**Pros:** Budget headroom without touching the existing clk_sys domain.
All existing framework modules stay at 20 MHz.

**Cons:**
- Requires 2 CDC crossings minimum (bitstream FIFO, frame output).
- Each crossing is a potential source of the kind of bugs this project
  has already suffered.
- The DPB memory path still crosses to clk_ddr for DDR access — same
  problem as Option A, crossing #2.
- VCO achievability must be confirmed by running the fitter (w-cap).

**Verdict: VIABLE but not needed now.** Hold in reserve if the 20 MHz
margin proves insufficient after implementation. The PLL has spare outputs.

### Option C: Raise `clk_sys` itself

**What depends on clk_sys = 20 MHz (traced from Plex.sv):**

| Module | clk_sys dependency | Impact of change |
|--------|-------------------|------------------|
| `hps_io` (Plex.sv:130) | Framework interface to ARM HPS | **CRITICAL** — MiSTer framework assumes specific timing |
| `present_core` (Plex.sv:737) | Video timing generation, ce_pix | Pixel clock ratios change, display breaks |
| `CLK_VIDEO = clk_sys` (Plex.sv:825) | Video scaler input | All video timing must be re-derived |
| `frame_store` / `ddr_frame_store` | Write/read timing | Affects DDR arbitration |
| `audio_fifo` | Audio sample timing | 48 kHz relationship changes |
| `AUDIO_S/L/R` (Plex.sv:831) | Audio output | Derived from CLK_AUDIO, probably OK |
| `ddram_frame_rd` | DDR DMA engine | Burst timing changes |
| `sdram_memtest` + `sdram` | SDRAM controller (via clk_sdram, separate) | Indirect only |
| Status telemetry | ~1 kHz update rate from st_div counter | Harmless |

**This is the highest-risk option.** The MiSTer framework (`sys_top.v`,
`hps_io.v`, video scaler) is shared infrastructure across hundreds of cores.
Changing clk_sys requires re-validating the entire framework integration.
The `ce_pix` pixel-clock enable, the OSD overlay, the DDR DMA — all assume
20 MHz base timing.

**Verdict: NOT RECOMMENDED.** Too many dependants, too much risk, not needed.

### Option D: Increase parallelism (RECOMMENDED)

**Key insight:** The bottleneck at 20 MHz is not compute but memory
bandwidth. The single most impactful change is widening the DPB interface
from 8-bit to 64-bit.

| Parallelism upgrade | Cycles saved | Complexity |
|---------------------|-------------|------------|
| 64-bit DPB bus | **820 cycles/MB** (988 → 168) | Medium: redesign fetch FSM |
| 4-wide MC FIR | ~288 cycles/MB (384 → 96) | Medium: 24 DSP blocks |
| 2-wide deblock edge | ~48 cycles/MB (96 → 48) | Low: duplicate edge pipe |
| 4×4 block-parallel IDCT | 0 (already combinational) | N/A |

**The 64-bit DPB redesign alone is sufficient.** It converts a 1.44×-over-budget
design into one with 59% margin. The other parallelism upgrades are
optimisations, not requirements.

**DSP budget (5CSEBA6U23I7):** 112 × 18×18 multipliers available.
- 4 FIR units × 6 taps = 24 multipliers (21%)
- Dequant: uses shift/add, no DSPs
- IDCT: uses shift/add, no DSPs
- Remaining: 88 multipliers for future use (chroma subpel, etc.)

### Option E: Reduce scope

If all else fails:

| Reduction | New budget | Impact |
|-----------|-----------|--------|
| 624×480 @ 20 fps | 855 cyc/MB | 25% more headroom |
| 480×360 @ 25 fps | 1,185 cyc/MB | 73% more headroom, visible quality loss |
| 320×240 @ 25 fps | 3,333 cyc/MB | 4.9× headroom, DVD → VHS quality |

**Verdict: Not needed.** The cycle model shows 624×480 @ 25 fps fits at
20 MHz with the 64-bit DPB upgrade.

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

- **Option A (move to clk_ddr):** Would need to close timing at 11.1 ns
  period (90 MHz) for the entire decode pipeline. Given that even 20 MHz
  has CDC-related failures, this is risky.
- **Option B (new PLL output):** Creates new CDC crossings, which are the
  exact failure mode. Each new crossing must be properly synchronised.
- **Option D (wider datapaths at 20 MHz):** No new clock domains. The
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
   introduce a new clock domain. The cycle budget is sufficient, and new
   CDC crossings are the project's highest-risk failure mode.

3. **Plan MC interpolation as time-multiplexed with 4 parallel FIR units.**
   The existing combinational `h264_inter_mc_16x16` is a simulation model,
   not a synthesis target. Budget 24 DSP blocks for the FIR array.

4. **P_Skip fast path:** When `skip_zero` is asserted (MV = 0,0), bypass
   the FIR entirely and copy the co-located 16×16 reference block directly.
   This is the dominant case for movie content and reduces average cost
   from ~404 to ~144 cycles/MB.

### 7.2 Implementation order

1. 64-bit DPB controller (w-rel / w-mc) — **gating**
2. Time-multiplexed MC FIR (w-mc) — **gating**
3. Deblock scheduler integration (w-rel) — **needed for correctness**
4. P_Skip fast path — **optimisation, do after basic pipeline works**
5. I16 Plane + I_PCM (w-plane) — **needed for real content**

### 7.3 Monitoring

After the MC datapath is built, w-c1 should measure the actual per-stage
cycle counts on real content and compare against this model. The key
numbers to watch:

- DPB fetch cycles/MB (target: ≤170)
- MC interpolation cycles/MB (target: ≤100)
- Deblock cycles/MB (target: ≤130)
- Total pipeline cycles/MB (target: ≤500, hard limit: 684)

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
| CAVLC = 3.2 cyc/MB | w-c1 measurement | Reported (not independently verified) |
| 100 MHz budget = discredited | `p3-mc-dpb-bandwidth.md`: uses wrong clock | Debunked ✓ |
| MC interpolation = 96 cyc/MB | First-principles estimate, 4-wide FIR | **Estimate** |
| Deblocking = 126 cyc/MB | First-principles estimate, 48 edges × 2 + overhead | **Estimate** |
| P_Skip fraction = 60–80% | Typical movie content heuristic | **Assumption** |
| VCO ≈ 720 MHz | Inference from PLL constraints | **Unverified** |

---

## 9. Open Questions

1. **Exact VCO frequency** — w-cap should confirm by inspecting fitter
   output or running a trial fit. This determines what intermediate
   frequencies are available if Option B is ever needed.

2. **Actual CAVLC worst-case** — w-c1 should measure on a complex I-frame
   to bound the worst case. The 3.2 average is fine for throughput
   planning but a worst-case MB could stall the pipeline.

3. **DDR arbitration contention** — The DPB shares the DDR bus with
   `ddr_frame_store` (present path) and `ddr_bitstream_reader` (stream
   path) via `ddr_bus_arbiter`. Under contention, DPB fetch cycles will
   increase. w-a3's arbiter design must guarantee worst-case latency
   bounds. The current arbitration is round-robin with no priority or
   latency guarantee.

4. **Sub-MB partitions** — The cycle model assumes P_L0_16×16 (one
   motion vector per MB). P_L0_16×8 and P_L0_8×16 require two reference
   fetches; P_8×8ref requires four. With 64-bit coalescing, the per-fetch
   overhead is smaller, but multi-partition MBs could reach ~400–500
   cycles. Still within budget but worth measuring.

5. **I16 Plane correctness on DSP budget** — w-plane's implementation
   must use shift-add, not DSP multipliers, to preserve the DSP budget
   for MC FIR. Verify this constraint is communicated.

---

*This study is a living document. Update it when measured numbers replace
estimates. Every number has a provenance — keep it that way.*
