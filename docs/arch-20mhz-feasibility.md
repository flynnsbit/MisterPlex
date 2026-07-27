# Architecture Study: Can H.264 Decode Fit at 20 MHz?

**Author:** w-arch  
**Date:** 2026-07-27  
**Branch:** feat/arch-study  
**Status:** v3.1 — **20 MHz is an inherited default, not a design choice.
Decode should have its own clock at 60 MHz (ESTIMATED — pending fit validation).**

---

## Executive Summary

**v3 reverses the framing of v1–v2.** The question was "can the decode
pipeline fit at 20 MHz?" The correct question is: **"why would we force it
to?"**

### Finding: 20 MHz was never chosen

`pll_0002.v` in MiSTerPlex is **byte-for-byte identical** to the
`Template_MiSTer` file (SHA `c599468`). The 20 MHz `outclk_0` was committed
at `44a4611` with the message *"Template-based Plex.rbf"* and has never been
revisited. No commit in the project's history changes, discusses, or
justifies the 20 MHz figure.

This is the **fifth** ceiling in this project that turns out to be an
inherited default rather than a design choice:

| # | Claimed ceiling | Actual status |
|---|----------------|---------------|
| 1 | SDRAM "pinned at 100 MHz" | `else` fallback; MemTest passes **142–167 MHz** |
| 2 | DDRAM_CLK "is 20 MHz" | Legacy template; now **90 MHz** (ao486 precedent) |
| 3 | "Baseline profile impossible to force" | Server-side profile override works |
| 4 | "Timing cannot close, -2.137 ns" | Root cause: arbiter on wrong clock domain |
| 5 | **`clk_sys` = 20 MHz** | **Template default. Never chosen.** |

### Finding: decode does NOT need to share clk_sys with video

The reason `clk_sys` is 20 MHz is **video timing**, not decode:

```
colorbars.sv:52-54:
    if (scandouble) ce_pix <= 1'b1;     // pixel rate = clk (20 MHz)
    else            ce_pix <= ~ce_pix;  // pixel rate = clk/2 (10 MHz)
```

This produces **10 MHz NTSC / 10 MHz PAL** pixel rates → 59.82 / 50.24 Hz.
Raising `clk_sys` would change the pixel rate and break display output —
**unless `ce_pix` is adjusted**, which is explicitly supported by the MiSTer
framework:

```
video_mixer.sv:26:
    input CLK_VIDEO, // should be multiple by (ce_pix*4)
```

The framework expects `CLK_VIDEO ≥ ce_pix_rate × 4`. The video scaler does
NOT require `CLK_VIDEO` to equal the pixel rate.

But the cleanest path is even simpler: **do not change `clk_sys` at all.**
Add a 4th PLL output for decode and leave the present path untouched.

### Finding: the crossing cost is ONE async FIFO

v2 enumerated 6 CDC crossing groups and ~285 signal wires. That was the
cost of moving `stream_path` in its entirety to a new clock. But the actual
decode pipeline has a much narrower coupling to clk_sys than that analysis
assumed:

1. **Bitstream input** — already buffered through `bitstream_fifo`
   (32K deep, clk_sys domain). Convert this to `async_fifo` (write on
   clk_sys, read on clk_decode). **One module change.** The `async_fifo`
   module already exists, is proven by w-a3's arbiter fix (`3c6d1d2`).

2. **DDR bus** — already crosses to `clk_ddr` (90 MHz) through
   `ddr_bus_arbiter` with async FIFO. The decode pipeline accesses DDR
   through this existing crossing. **No new crossing needed** — decode on
   a 40–90 MHz clock talks to the arbiter the same way stream_path does
   today.

3. **Frame output** — in the `DDR_FRAME_STORE` architecture (which is the
   production path), decoded frames are written to DDR through the arbiter.
   The present path reads from DDR via `ddr_frame_store`. **The coupling
   between decode and present is through DDR memory, not through direct
   signals.** No new crossing needed.

4. **Status telemetry** — residual_csum, recon_sig, etc. Multi-cycle,
   changes at MB boundaries (~30 kHz). Standard 2-FF synchronizers.
   **Trivial.**

5. **Control** — reset, flush. Quasi-static. 2-FF synchronizers. **Trivial.**

**Total new CDC work: convert `bitstream_fifo` to async + add 2-FF syncs
for telemetry. Estimated effort: 2–3 days, not weeks.**

### Recommendation

**Add a 4th PLL output (`clk_decode`) at 60 MHz.** Run the decode
pipeline — from bitstream FIFO read port through CAVLC, dequant/IDCT, intra
pred, MC interpolation, deblocking, to DPB writeback — on `clk_decode`.
Leave everything else on `clk_sys` (20 MHz) untouched.

| Clock | Frequency | Budget (cyc/MB) | Margin over 608 total |
|-------|-----------|-----------------|----------------------|
| 40 MHz | 40 MHz | 1,368 | 2.25× (fallback) |
| **60 MHz** | **60 MHz** | **2,051** | **3.37×** |
| 90 MHz | 90 MHz | 3,077 | 5.1× (not recommended — timing risk) |

**Why 60, not 40 (v3's target)?** Fabric analysis (§6) shows the critical
path is ~12 logic levels (parse_cavlc, deblock — both sequential, not
pipelinable). At conservative 1.0 ns/level, the critical path is 12.3 ns.
60 MHz (16.7 ns period) closes with **4.1 ns margin**. 40 MHz (25.0 ns)
wastes 75% of the period. The CDC cost is identical at either frequency.
If 60 MHz fails timing, fall back to 48 → 40 MHz (PLL parameter only, no
structural changes).

At 60 MHz, the 250-cycle MC target becomes **750 cycles**, and the
adjacent-MB overlap cache changes from MANDATORY to nice-to-have. Even
byte-serial DPB (988 cycles) fits trivially at 2,051.

**This does NOT mean parallelism work is wasted.** A wider DPB and
efficient MC are still good engineering. But they become optimisations
that buy power and thermal headroom, not architectural requirements that
gate the project.

**STATUS: 60 MHz target is ESTIMATED, not MEASURED. The critical path
analysis is first-principles (§6). The only honest validation is a fit.
Until w-cap confirms VCO and runs a trial fit with the 4th output,
every frequency claim in this document is an estimate and should be
quoted as such. Do not let "60 MHz" acquire the same false authority
that "100 MHz / 3418 cycles" had.**

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

### PLL spare output analysis — REVISED v3.1

Cyclone V GPLL VCO range (speed grade 7, I-grade): **600–1300 MHz**.

The fitter must find M, N such that VCO = 50 × M/N lands in [600, 1300] and
VCO/C produces all three requested frequencies. The altera_pll IP takes
requested frequencies as targets and finds the best M/N/C combination
minimising total error across all outputs.

**VCO candidates (computed, see Provenance):**

| VCO (MHz) | M | N | C0→20 | C1→142 (actual) | C2→90 | Feasible? |
|-----------|---|---|-------|------------------|-------|-----------|
| **720** | 72 | 5 | 36 (exact 20) | 5 (→144, err 1.4%) | 8 (exact 90) | **Most likely** |
| 900 | 18 | 1 | 45 (exact 20) | 6 (→150, err 5.6%) | 10 (exact 90) | 142 error too high |
| 1080 | 108 | 5 | 54 (exact 20) | 8 (→135, err 4.9%) | 12 (exact 90) | 142 error too high |
| 1260 | 126 | 5 | 63 (exact 20) | 9 (→140, err 1.4%) | 14 (exact 90) | Possible |

**VCO = 720 MHz is the most likely choice** — it gives exact 20 and 90,
and the SDRAM clock error (144 vs 142 = 1.4%) is within SDRAM tolerance.
VCO = 1260 gives 140 MHz (also 1.4% off), but a higher VCO is chosen only
if needed for jitter or other reasons. **Provenance: COMPUTED from PLL
constraints, UNVERIFIED until w-cap confirms from fitter output.**

**Available 4th-output frequencies (VCO = 720 MHz):**

| Frequency | C-counter | Period | Budget (cyc/MB) | vs. 608 total |
|-----------|-----------|--------|-----------------|---------------|
| 120 MHz | 6 | 8.3 ns | 4,103 | 6.75× |
| 90 MHz | 8 | 11.1 ns | 3,077 | 5.06× |
| 80 MHz | 9 | 12.5 ns | 2,735 | 4.50× |
| 72 MHz | 10 | 13.9 ns | 2,462 | 4.05× |
| **60 MHz** | **12** | **16.7 ns** | **2,051** | **3.37×** |
| 48 MHz | 15 | 20.8 ns | 1,641 | 2.70× |
| 45 MHz | 16 | 22.2 ns | 1,538 | 2.53× |
| 40 MHz | 18 | 25.0 ns | 1,368 | 2.25× |
| 36 MHz | 20 | 27.8 ns | 1,231 | 2.02× |
| 30 MHz | 24 | 33.3 ns | 1,026 | 1.69× |

If VCO = 1260 MHz, additional options include 63, 70, 84, and 105 MHz.
The set is wide enough that frequency choice is NOT PLL-constrained — it
is fabric-timing-constrained (see §6).

**Provenance: COMPUTED from Integer-N PLL arithmetic. UNVERIFIED VCO.
The frequency set is correct for VCO=720; different VCO → different set.
w-cap must confirm VCO from fitter output before committing to a target.**

### 1A. Provenance of the 20 MHz Value (NEW in v3)

**Method:** `git log --all --follow -p pll_0002.v`, plus comparison with
Template_MiSTer source (`c599468`).

**Finding: the 20 MHz value is the Template_MiSTer default and has never
been changed in MiSTerPlex.**

| Evidence | Detail |
|----------|--------|
| Initial commit | `44a4611` message: *"Template-based Plex.rbf"* |
| File comparison | `pll_0002.v` in MiSTerPlex is byte-for-byte identical to Template_MiSTer's `pll_0002.v` |
| Subsequent changes | No commit in project history modifies `output_clock_frequency0` |
| Template value | `output_clock_frequency0("20.000000 MHz")` — round number, machine-generated default |

**Cross-reference: ao486_MiSTer** (shipping production core on the same
device family) overrides `outclk_0` to **90 MHz** (`outclk0_requested = "90.0 MHz"`),
its VCO is 900 MHz, and it closes timing. This proves:

1. The template default IS routinely overridden by production cores
2. Cyclone V 5CSEBA6U23I7 CAN close timing at 90 MHz for complex logic

### 1B. What clk_sys Actually Feeds (NEW in v3)

Every consumer of `clk_sys` in `Plex.sv`, traced:

| Consumer | Line | Frequency-sensitive? | Notes |
|----------|------|---------------------|-------|
| `hps_io` | 127 | **No** — async SPI to ARM HPS | Works at any clock, PS2DIV adjustable |
| `colorbars` (present_core) | 588 | **YES** — derives pixel timing | `ce_pix` produces pixel rate relative to clk |
| `video_mixer` (sys_top) | 1784 | **YES** — uses `CLK_VIDEO = clk_sys` | BUT: comment says "should be multiple by (ce_pix*4)" — explicitly supports CLK > pixel rate |
| `stream_path` (decode) | 588 | **No** — pure throughput | Faster clock = more cycles/MB, strictly beneficial |
| `ddr_bus_arbiter` | 784 | **No** — already moved to `clk_ddr` by w-a3 | On w-a3's branch, runs at 90 MHz |
| `osd_out` (sys_top) | — | Low bandwidth | 2-FF sync sufficient |
| Status/telemetry | 588+ | Low bandwidth | Changes at MB rate (~30 kHz), trivially syncable |

**Key insight:** The ONLY component that requires `clk_sys = 20 MHz` is the
video output timing in `colorbars.sv`, and even that is a soft requirement
because `video_mixer.sv` explicitly supports `CLK_VIDEO > pixel_rate`.

**However, the cleanest approach does NOT change `clk_sys` at all.** It adds
a 4th PLL output and runs only the decode pipeline on it.

### 1C. Decode ↔ Present Coupling Analysis (NEW in v3)

In the `DDR_FRAME_STORE` architecture:
- Decode writes reconstructed MBs to DDR (through `ddr_bus_arbiter`, already clk_ddr domain)
- Present reads frames from DDR (through `ddr_frame_store`, already clk_ddr domain)
- **The coupling between decode and present goes through DDR memory** — they do not exchange direct signals

This means decode and present can run on DIFFERENT clocks with ZERO additional
CDC crossings on the frame data path. The DDR arbiter is already the crossing
boundary.

**Signals that DO need CDC if decode moves to clk_decode:**

| Crossing | Direction | Width | Rate | Solution | Effort |
|----------|-----------|-------|------|----------|--------|
| bitstream_fifo | clk_sys → clk_decode | 8-bit data + control | Streaming | Convert to `async_fifo` (exists, proven at `3c6d1d2`) | 2 days |
| residual_csum, recon_sig | clk_decode → clk_sys | ~32 bits | MB rate (~30 kHz) | 2-FF synchronizer | Hours |
| decode_active, flush | clk_sys → clk_decode | 1–2 bits | Quasi-static | 2-FF synchronizer | Hours |
| reset | clk_sys → clk_decode | 1 bit | Once at startup | Async reset synchronizer | Hours |

**Total: 1 async FIFO conversion + ~4 two-FF synchronizers.**
Compare to v2's analysis of full clk_ddr migration: 6 crossing groups, ~285 signals.

---

## 2. Frame Budget (Confirmed — extended with clk_decode scenarios)

```
Resolution:       624 × 480 = 39 × 30 = 1170 macroblocks/frame
Frame rate:       25 fps
MB throughput:    1170 × 25 = 29,250 MB/s
clk_sys:          20,000,000 Hz
Budget @ 20 MHz:  20,000,000 / 29,250 = 683.76 ≈ 684 cycles/MB
```

**With a dedicated decode clock:**

| clk_decode | Cycles/MB | vs. 608 total | Margin | MC ceiling |
|------------|-----------|---------------|--------|------------|
| 20 MHz     | 684       | 1.12×         | 76     | 250 (TIGHT) |
| 40 MHz     | 1,368     | 2.25×         | 760    | 1,010 |
| 60 MHz     | 2,051     | 3.37×         | 1,443  | 1,693 |
| 90 MHz     | 3,077     | 5.06×         | 2,469  | 2,719 |

At 40 MHz, MC gets 1,010 cycles — **byte-serial DPB reference fetch (988
cycles) fits, and the 64-bit coalesced DPB changes from mandatory to optional
for budget reasons.** Adjacent-MB cache changes from mandatory to nice-to-have.
At 60 MHz, even a naive implementation with headroom to spare.

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

## 4. Verdict — REVISED in v3

### v1–v2 verdict: "20 MHz is tight but feasible" — SUPERSEDED

v1–v2 concluded that 20 MHz was sufficient under two non-negotiable conditions
(64-bit coalesced DPB and adjacent-MB reference cache). That analysis was
correct **given the assumption that 20 MHz was a fixed constraint.**

### v3 verdict: 20 MHz is an unnecessary constraint. Give decode its own clock.

The 20 MHz frequency was never intentionally chosen (§1A). It is a template
default that has been overridden by every non-trivial MiSTer core. The decode
pipeline does not need to share a clock with the present path (§1C) — their
coupling goes through DDR memory, which already lives in a different clock
domain.

**Continuing to optimise the decode pipeline under a 684-cycle ceiling
is engineering effort spent solving a problem that a PLL parameter deletes.**

The conditions from v1–v2 remain **good engineering** (wider DPB and efficient
MC are valuable for power and thermal headroom), but they change from
**architectural requirements** to **optimisations** once the clock ceiling lifts.

### The recommendation

**Add a 4th PLL output (`clk_decode`) in the range 40–90 MHz.** Run the
decode pipeline on it. Leave `clk_sys` at 20 MHz for video timing. The CDC
cost is 1 async FIFO (bitstream_fifo) + ~4 two-FF synchronizers — roughly
2–3 days of work, not weeks. See §1B and §1C for the full crossing analysis.

**Suggested starting point: 40 MHz.** This is conservative:
- Budget: 1,368 cycles/MB (2× current)
- MC gets ~500 cycles (relaxes the 250 ceiling that drives the entire
  parallelism architecture)
- Likely achievable without timing closure struggle (well below ao486's
  proven 90 MHz)
- If 40 MHz proves comfortable, the same PLL can be adjusted upward later

**Why not jump straight to 90 MHz?** Because it is unnecessary for this
resolution/framerate, and because every incremental MHz makes timing closure
harder. 40 MHz doubles the budget; the remaining uncertainty in MC and
deblock easily fits in 1,368 cycles.

### What this changes for other workers

| Worker | Impact |
|--------|--------|
| **w-mc** | 250-cycle ceiling relaxes to ~500 (at 40 MHz). Adjacent-MB cache becomes nice-to-have, not mandatory. 64-bit DPB still recommended for efficiency but byte-serial doesn't break the budget. |
| **w-c1** | Ratchet budget doubles; TIGHT → COMFORTABLE. All three unbuilt stages have generous allocations. |
| **w-a3** | One new async FIFO (bitstream), which is a repeat of their arbiter pattern. Not a new category of risk. |
| **w-cap** | PLL modification needed; must confirm VCO and achievable C-counter values. Owns the re-fit. |
| **w-plane** | I16 Plane's ~70 cycles no longer eat the margin — there IS no margin problem. |
| **w-deblock** | 150 cycles easily available, with room for a simpler implementation. |

---

### v1–v2 detailed analysis preserved below for reference

*The following sections (§4A–§4C) were the v1–v2 verdict. They remain correct
as an analysis of the 20 MHz case, but the v3 recommendation above supersedes
the conclusion that 20 MHz should be the target.*

#### 4A. Original conditions (still good engineering, no longer mandatory)
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
intra-domain timing failures**. This means the 20 MHz domain has
significant timing margin — possibly 20–30 ns of positive slack (we
need w-cap's post-fix STA to confirm the exact number).

### v3.1: Decode fabric frequency ceiling (REVISED — sourced analysis)

**Known datapoints:**
1. **ao486** (shipping production core, same device family) closes timing
   at 90 MHz (VCO = 900 MHz) for a CPU core with complex decode and
   execution logic. This proves 90 MHz is achievable on Cyclone V
   5CSEBA6U23I7 for moderately complex logic.

2. **MiSTerPlex's own `clk_ddr` = 90 MHz** is already closing timing for
   the DDR bus arbiter, frame store, and async FIFOs on this device.

3. **No intra-domain timing failures at 20 MHz.** The 50 ns period gives
   enormous margin for ALM-based combinational logic.

4. **w-plane demonstrated that combinational depth is a property of RTL
   quality, not algorithmic complexity.** I16 Plane went from 55–70 levels
   (combinational, 512 multipliers) to 18/8 levels (2-cycle pipeline, 32
   multipliers) by pre-computing the 32 distinct products. A sixteen-fold
   multiplier reduction and four-fold depth reduction for two cycles.

**Combinational depth analysis of each decode stage (with proper pipelining):**

| Stage | Depth (levels) | Notes | Pipelinable? |
|-------|---------------|-------|-------------|
| parse_cavlc | **12** | Exp-Golomb: shift register + comparator + mux | **No** — sequential state machine |
| deblock | **12** | Threshold compare + conditional 4-tap filter | **No** — data-dependent decisions |
| dequant_idct | 10 | Pipelined butterfly, 2 stages of 10 | Yes, at 2-cycle cost |
| intra_pred | 10 | Mode mux + boundary interpolation | Partially |
| mc_chroma | 8 | 2×2 bilinear, shift+add | Yes |
| i16_plane | 8 | After w-plane pipelining (cy2) | Already done |
| residual_add | 8 | signed [21:0] add + clip (w-cabac widened) | N/A — single operation |
| ddr_addr | 8 | 28-bit add + base offset | N/A — single operation |
| **mc_fir_h/v** | **7** | **6-tap FIR with shift+add (see below)** | Yes, registered between H/V |
| mc_qpel_avg | 3 | add + shift + clip | N/A — trivial |

**Critical path: parse_cavlc and deblock, both at 12 levels.** These are
NOT easily pipelinable because they involve sequential state machines and
data-dependent branching. **They set the hard frequency ceiling.**

**Key insight: the 6-tap MC FIR is NOT the critical path** (contrary to v3).
The H.264 half-pel coefficients {1, -5, 20, 20, -5, 1} decompose via
symmetry:

```
result = (a+f) + 20*(c+d) - 5*(b+e)
where: 20x = (x<<4) + (x<<2)   ← shift+add, no DSP
        5x = (x<<2) + x        ← shift+add, no DSP
```

This gives **~7 logic levels** per FIR pass (3 parallel adds → shift+add
for 20× and 5× → 2 combines → round+shift → clip). With a register between
horizontal and vertical passes, the FIR contributes 7 levels to the critical
path — **less than parse_cavlc or deblock.** No DSP blocks are needed for
the standard FIR coefficients.

**Frequency ceiling estimate (critical path = 12 levels):**

| Routing model | Delay estimate | Max frequency | Status |
|--------------|---------------|---------------|--------|
| 0.70 ns/level (aggressive, short routes) | 12×0.70+0.3 = 8.7 ns | **115 MHz** | ESTIMATED |
| 0.85 ns/level (moderate) | 12×0.85+0.3 = 10.5 ns | **95 MHz** | ESTIMATED |
| **1.00 ns/level (conservative)** | **12×1.0+0.3 = 12.3 ns** | **81 MHz** | **ESTIMATED** |
| 1.20 ns/level (pessimistic, long routes) | 12×1.2+0.3 = 14.7 ns | **68 MHz** | ESTIMATED |

**Conservative estimate: the fabric can close at 60–80 MHz.** Even at
the pessimistic 1.2 ns/level model, 60 MHz closes with +2.0 ns margin.

**Factors cutting against frequency:**

1. **w-cabac's wider residual (signed [21:0]):** Adds ~4 bits of carry chain.
   On Cyclone V, the dedicated carry chain runs at ~0.07 ns/bit, so the
   impact is ~0.3 ns. **Negligible at any frequency below 90 MHz.** This
   was a concern in v3; it is not a concern with measured carry-chain speed.

2. **Deblock filter (unbuilt):** Estimated at 12 levels but this is an
   estimate — w-deblock is building it now. If the filter turns out deeper
   (e.g., 15-18 levels due to complex conditional logic), the ceiling drops.
   w-c1's revised allowance of 150 cycles gives w-deblock room to pipeline.

3. **Routing congestion:** High device utilisation can force the placer to
   use longer routes, increasing per-level delay. The current design is not
   near utilisation limits (`ddr_frame_store` is ~4116 ALUTs; total decode
   path is estimated at <15K ALUTs of 41K available), so this is unlikely
   to dominate.

### v3.1 conclusion: why 60 MHz, not 40

**v3 recommended 40 MHz. That was a comfortable doubling, not a sourced
limit.** The parent correctly identified this as the same pattern that
produced 20 MHz — a round number nobody examined.

The fabric analysis says:
- 40 MHz closes with **12.4 ns margin** — wasting 75% of the period
- 60 MHz closes with **4.1 ns margin** — reasonable engineering margin
- 72 MHz closes with **1.3 ns margin** — tight, risky on speed grade 7
- 80+ MHz closes only at moderate or aggressive routing assumptions

**60 MHz is the right target** because:
1. It closes conservatively (4.1 ns margin at 1.0 ns/level)
2. Budget = **2,051 cycles/MB** (3× the 20 MHz budget)
3. MC ceiling relaxes to ~750, well above even a naive implementation
4. CDC cost is identical to 40 MHz (same crossings, same FIFOs)
5. Available from VCO=720 as C=12 (exact integer division)
6. Available from VCO=1260 as C=21 (exact integer division)
7. **Still conservative** — ao486 closes at 90 MHz, and 60 is 2/3 of that

**The fallback ladder costs nothing structural:**

```
60 MHz → timing fails? → 48 MHz (PLL parameter change only)
48 MHz → timing fails? → 40 MHz (PLL parameter change only)
40 MHz → timing fails? → 20 MHz + v1-v2 tight architecture
```

Each step is a single PLL parameter edit in `pll_0002.v`. No structural
changes, no CDC re-work, no module redesign. The async FIFO and 2-FF
synchronizers work identically at any of these frequencies.

**Why not go higher?** 72 MHz has only 1.3 ns margin (conservative model),
which is uncomfortably close for speed grade 7. 80+ MHz requires aggressive
routing assumptions. 90 MHz matches clk_ddr (which is already proven) but
eliminates the benefit of a separate clock — if decode runs at 90 MHz, it
might as well share clk_ddr, and then we are back to the full CDC migration
that v2 priced at 4–6 weeks.

**Why not go straight to 90 MHz "since the CDC cost is the same"?** Because
the CDC cost is NOT the only cost — timing closure effort is proportional to
the inverse of the slack margin. At 60 MHz with 4.1 ns margin, the fitter has
room to place and route without constraint pressure. At 90 MHz with negative
margin, every synthesis iteration becomes a timing-closure battle. This
project has **never successfully fitted with positive slack** (the -2.137 ns
was a CDC error, but we do not yet have a clean baseline). Starting with a
target that has a 4 ns margin gives us a known-good baseline before pushing.

**STATUS: ALL ESTIMATES until post-fix STA confirms intra-domain slack. The
12-level critical path is a first-principles model, not a synthesis result.
The only honest measurement is a fit with the 4th PLL output at 60 MHz.**

---

## 7. Recommendations — REVISED v3.1

### 7.1 Primary recommendation: dedicated decode clock at 60 MHz

**Add a 4th PLL output (`clk_decode`) at 60 MHz.** Run the decode
pipeline on it. Leave `clk_sys` at 20 MHz for video, HPS, OSD.

**Why 60, not 40 (answering parent's challenge):**

| Criterion | 40 MHz | 60 MHz | 90 MHz |
|-----------|--------|--------|--------|
| Period | 25.0 ns | 16.7 ns | 11.1 ns |
| Margin vs 12-level critical path (conservative) | +12.4 ns | **+4.1 ns** | -1.2 ns |
| Budget (cyc/MB) | 1,368 | **2,051** | 3,077 |
| MC ceiling | ~500 | ~750 | ~1,100 |
| CDC cost | Same | Same | Same |
| Fallback if timing fails | → 36 MHz | **→ 48 MHz → 40 MHz** | → 80 MHz → 72 MHz |
| Risk | Wastes 75% of period | Reasonable margin | Timing closure battle |

40 MHz was v3's recommendation. It was a comfortable doubling — the same
pattern that produced the 20 MHz default. The fabric analysis (§6) shows
the critical path is ~12 levels (parse_cavlc, deblock), giving a conservative
ceiling of ~81 MHz. 40 MHz wastes 75% of the available period. 60 MHz uses
it efficiently while retaining 4.1 ns margin. **The CDC work is identical.**

**Implementation steps (unchanged from v3 except frequency):**

1. **w-cap:** Confirm actual VCO frequency from fitter output. Add 4th
   output at 60 MHz (VCO=720: C=12, exact; VCO=1260: C=21, exact).
   Add SDC constraint: `create_clock -period 16.667 [get_pins {pll|...outclk_3}]`.

2. **w-a3:** Convert `bitstream_fifo` to `async_fifo` (write clk_sys,
   read clk_decode). Add 2-FF synchronizers for status/control.
   **Estimated effort: 2–3 days.**

3. **w-rel:** Wire `clk_decode` to `stream_path` in place of `clk_sys`.

4. **w-c1:** Re-derive budget at 60 MHz: 2,051 cycles/MB. Reallocate.

5. **w-mc:** Design to the relaxed ceiling (~750 cycles). Pipelining
   discipline remains important for timing closure, not for cycle budget.

5. **w-mc:** Design MC interpolation with a **relaxed ceiling** (~500 cycles
   at 40 MHz). Adjacent-MB cache is still good engineering but no longer
   gate-blocking. 64-bit DPB is still recommended for efficiency.

### 7.2 Why not raise clk_sys directly?

- `ce_pix` in `colorbars.sv` derives pixel timing from `clk_sys`
- `video_mixer.sv` can handle CLK_VIDEO > pixel rate, but would need
  `ce_pix` to be re-derived as a `1-in-N` strobe instead of a toggle
- Every MiSTer framework module (OSD, scaler, gamma) sees the changed clock
- **Risk is MUCH higher than adding a PLL output** for no additional benefit

### 7.3 Why not 90 MHz "since the CDC cost is the same"?

The CDC cost IS the same — but timing closure effort is not.

1. **No clean baseline exists.** This project has never fitted with positive
   intra-domain slack. The -2.137 ns was a CDC error, but we do not yet have
   an honest slack figure for any domain.
2. **Timing closure effort is proportional to 1/margin.** At 60 MHz the
   fitter has 4.1 ns of routing slack. At 90 MHz it has -1.2 ns (conservative
   model) and every synthesis iteration becomes a constraint battle.
3. **90 MHz on clk_decode eliminates the rationale for a separate clock.**
   If decode runs at 90 MHz, it could share clk_ddr (which already exists
   at 90 MHz) — but that is the full CDC migration v2 priced at 4–6 weeks.
4. **Fallback from 90 MHz failure is expensive.** If 90 MHz doesn't close,
   you must re-fit at a lower frequency AND possibly rework pipelining.
   Fallback from 60 MHz failure is a PLL parameter change.

### 7.4 v1–v2 recommendations preserved (still valid as good engineering)

The following remain recommended even with a faster decode clock, because
they reduce power, DDR bandwidth contention, and leave headroom for future
resolution increases:

1. **64-bit coalesced DPB** — reduces DDR bus pressure 8× for reference fetch
2. **Adjacent-MB reference cache** — reduces redundant DDR traffic
3. **P_Skip fast path** — bypasses FIR for zero-MV blocks (60–80% of P-MBs)
4. **Shift+add MC FIR** — the H.264 half-pel coefficients {1,-5,20,20,-5,1}
   decompose to shift+add via symmetry, eliminating DSP block usage entirely
   for the standard FIR. DSP blocks remain available for chroma interpolation
   or future extensions.

### 7.5 Pipelining discipline (NEW — informed by w-plane's result)

w-plane demonstrated that I16 Plane went from 55–70 combinational levels
to 18/8 levels by pre-computing the 32 distinct products into registers.
**This technique applies across the decode path.** Any stage that will run
on `clk_decode` at 60 MHz (16.7 ns period) must limit its combinational
depth to ~12 levels. Specifically:

- **w-mc:** The 6-tap FIR with shift+add decomposition is ~7 levels per
  pass. Register between horizontal and vertical passes. **This is already
  below the ceiling.**
- **w-deblock:** The threshold-compare + conditional filter must stay at
  ≤12 levels. If the logic is deeper, pipeline with a register between
  the threshold decision and the filter application.
- **w-plane:** Already pipelined (cy1=18 levels is slightly above 12 — may
  need one more pipeline stage at 60 MHz. At 40 MHz fallback, it fits.)

### 7.6 Monitoring and escalation

At 60 MHz, the monitoring table becomes:

| Metric | Target | Hard limit (2051) | Action if exceeded |
|--------|--------|-------------------|-------------------|
| MC cycles/MB | ≤750 | ≤1200 | >1200 → investigate implementation, not clock |
| DPB fetch cycles/MB | ≤168 | ≤988 | Even byte-serial fits at 2051 |
| Deblock cycles/MB | ≤150 | ≤400 | >400 → pipeline deeper |
| Total pipeline cycles/MB | ≤1000 | ≤2051 | >2051 → frame drops |

**If timing closure fails at 60 MHz:** drop to 48 MHz (PLL parameter only).
Budget: 1,641 cycles/MB (2.70× over 608). Still comfortable.

**If timing closure fails at 48 MHz:** drop to 40 MHz. Budget: 1,368 cycles/MB
(2.25× over 608). Still adequate.

**If timing closure fails at 40 MHz:** this is genuinely surprising and suggests
a deeper problem (routing congestion, placement failures). Fall back to 20 MHz
and apply v1–v2 tight-budget architecture. No CDC work is wasted.

**Critical: w-plane's I16 Plane at 18 levels (cy1) may be the binding constraint
for 60 MHz.** At 1.0 ns/level, 18 levels = 18.3 ns > 16.7 ns period. Either:
(a) add one pipeline stage to Plane cy1 (splitting it to 9+9), or
(b) accept 48 MHz as the ceiling for the Plane case (18×1.0+0.3 = 18.3 ns →
    max 54 MHz), since Plane MBs are rare in typical content.
This should be coordinated with w-plane.

---

## 8. Provenance Ledger

| Fact | Source | Confidence |
|------|--------|------------|
| clk_sys = 20 MHz | `pll_0002.v` line 46: `output_clock_frequency0("20.000000 MHz")` | Traced ✓ |
| **20 MHz is Template_MiSTer default, never changed** | `git log --all --follow pll_0002.v`: initial commit `44a4611` identical to Template `c599468` | **Traced ✓ (v3)** |
| **ao486 uses 90 MHz for clk_sys on same device** | ao486 `pll_0002.v`: `outclk0_requested = "90.0 MHz"`, VCO = 900 MHz | **Traced ✓ (v3)** |
| **video_mixer explicitly supports CLK_VIDEO > pixel rate** | `sys/video_mixer.sv:26`: comment "should be multiple by (ce_pix*4)" | **Traced ✓ (v3)** |
| **hps_io has no clock frequency requirement** | `sys/hps_io.sv:37`: takes `clk_sys` generically, PS2DIV is a parameter | **Traced ✓ (v3)** |
| **ce_pix derives pixel rate from clk_sys** | `colorbars.sv:52–54`: toggle or always-high based on scandouble | **Traced ✓ (v3)** |
| **Decode ↔ present coupling is through DDR, not direct signals** | DDR_FRAME_STORE arch: decode writes DDR via arbiter, present reads DDR via ddr_frame_store | **Traced ✓ (v3)** |
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
| VCO ≈ 720 MHz | Computed from PLL constraints: LCM(20,90) with VCO in [600,1300] | **COMPUTED, UNVERIFIED** |
| **VCO=720: available outputs 30,36,40,45,48,60,72,80,90,120 MHz** | Integer-N PLL arithmetic: VCO/C for integer C | **COMPUTED (v3.1)** |
| **Critical path = 12 logic levels (parse_cavlc, deblock)** | First-principles depth analysis, all decode stages | **ESTIMATED (v3.1)** |
| **6-tap FIR = ~7 levels with shift+add symmetry decomposition** | {1,-5,20,20,-5,1}: (a+f)+20(c+d)-5(b+e), 20x=x<<4+x<<2 | **DERIVED (v3.1)** |
| **Conservative max freq = ~81 MHz (12 levels × 1.0 ns + 0.3 ns)** | Cyclone V ALM delay model, conservative routing | **ESTIMATED (v3.1)** |
| **60 MHz target closes with +4.1 ns margin (conservative model)** | 16.7 ns period - 12.3 ns critical path | **ESTIMATED (v3.1)** |
| **w-plane I16 Plane: 55-70 → 18/8 levels after pipelining** | w-plane report: pre-computed 32 products, 512→32 multipliers | **Reported (v3.1)** |
| **w-cabac carry chain impact: ~0.3 ns (4 extra bits)** | Cyclone V carry chain: ~0.07 ns/bit × 4 bits | **ESTIMATED (v3.1)** |
| **CDC cost for decode-only separation: 1 async FIFO + ~4 2-FF syncs** | Traced from stream_path ports and DDR_FRAME_STORE architecture | **Traced ✓ (v3)** |
| **Full clock migration: 6 groups, ~285 signals** | Enumerated from stream_path + DDR interface | Counted ✓ |

---

## 9. Open Questions — UPDATED v3

### Resolved by v3

~~1. Exact VCO frequency~~ → ao486 proves 900 MHz VCO is achievable on this
device. MiSTerPlex's VCO is fitter-chosen but ~720 MHz is the estimate.
**w-cap must confirm by running a trial fit with the 4th output added.**

~~7. Post-CDC-fix STA update~~ → The STA failures were CDC crossings, not
intra-domain timing. Once those crossings are fixed, the slack tells us
the INTRA-domain timing margin, which is what matters for the decode clock
frequency question. **Still need numbers from w-cap after the re-fit.**

### New questions (v3.1)

8. **VCO confirmation for 4th output.** What VCO does the fitter actually
   choose for the current 3-output PLL? Can a 4th output at 60 MHz be
   added without changing the VCO? At VCO=720: C=12 (exact). At VCO=1260:
   C=21 (exact). Both work. **w-cap owns this.**

9. **Intra-domain slack at 20 MHz.** After the CDC fixes land, what is the
   worst-case intra-domain slack for `clk_sys`? This directly tells us the
   frequency ceiling for the decode fabric. If slack is +20 ns at 20 MHz
   (period 50 ns), the fabric can close at 50/(50-20) = 33 MHz minimum.
   **w-cap owns this; coordinate after the next re-fit.**

10. **w-cabac's wider arithmetic impact.** The residual pipeline was widened
    from `signed [17:0]` to `signed [21:0]`. Longer carry chains. Does this
    affect timing closure at 40+ MHz? **Need STA data on the wider path.**
    At 40 MHz (25 ns period), a few ns of additional carry chain is likely
    fine; at 90 MHz (11.1 ns), it matters.

### Still open from v1–v2 (updated for 60 MHz context)

2. **Actual CAVLC worst-case** — 50-cycle allocation needs validation on
   complex I-frames. CAVLC is one of the 12-level critical paths. If it
   turns out deeper in practice, it may be the frequency ceiling.

3. **DDR arbitration contention** — worst-case latency bounds under
   multi-port contention. Less critical at 60 MHz (triple the budget).

4. **Sub-MB partitions** — P_L0_16×8, P_L0_8×16, P_8×8ref impact on MC
   cycles. Not critical at 60 MHz (750-cycle ceiling).

5. **I16 Plane DSP budget** — w-plane's shift-add approach preserves DSPs.
   **Additionally:** their cy1 at 18 levels may exceed 60 MHz ceiling.
   Coordinate with w-plane on whether a 3rd pipeline stage is needed.

6. **Adjacent-MB cache miss rate** — optimisation only at 60 MHz.

11. **w-plane I16 Plane cy1 = 18 levels vs 60 MHz.** At conservative
    1.0 ns/level, 18 levels = 18.3 ns > 16.7 ns period (60 MHz). Options:
    (a) split cy1 into two pipeline stages (9+9 levels, 3 total cycles),
    (b) accept that Plane MBs are rare and tolerate a local timing
    exception (multicycle path constraint), or (c) target 48 MHz.
    **This is potentially the binding constraint for 60 MHz.** Coordinate
    with w-plane immediately.

---

*This study is a living document. Update it when measured numbers replace
estimates. Every number has a provenance — keep it that way.*
