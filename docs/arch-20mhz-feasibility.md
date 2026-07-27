# Architecture Study: Can H.264 Decode Fit at 20 MHz?

**Author:** w-arch  
**Date:** 2026-07-27  
**Branch:** feat/arch-study  
**Status:** v5 — **The 39.86 ns critical path was in `decode_stub` (dead code).
The real decode fabric's frequency limit has NEVER BEEN MEASURED.
45 MHz remains the only safe CDC candidate. The clk_ddr violating path
(`disp_buf_d2 → DDRAM_ADDR`) is a candidate mechanism for the frozen screen.**

---

## Executive Summary

### v5: The 39.86 ns path was dead code — fabric limit is UNMEASURED

**w-cap extracted the actual endpoints of the 39.86 ns clk_sys path:**

```
FROM:   decode_stub|lat_qp[4]
TO:     decode_stub|recon_dbg[5]
slack:  +10.151 ns    data delay 39.227 ns    22 logic levels

All 10 worst intra-domain paths: same FROM/TO pair in decode_stub.
```

**`decode_stub` is a simulation and diagnostic shim. It is not the decoder.**
The 25.09 MHz Fmax figure I used in v4 to say the fabric "measurably cannot
exceed 25 MHz" was an artifact of a module the real decoder replaces. The
next-worst path is also `decode_stub` at 10.179 ns slack. **We have no
measurement of the real decode fabric's frequency limit.**

My v4 hypothesis — that the path went through `h264_luma_qpel_block_16x16`
— was wrong about the module but right about the mechanism: a massively
combinational block dominated the timing. **The conclusion survives in
stronger form than I argued:** I said if the path were eliminated by MC
replacement, the clock question reopens. The path is eliminated by decode_stub
removal. **The clock question is genuinely reopened — not as optimism, as
ignorance.**

### v4: Corrections from w-cap's fitter measurements (PARTIALLY SUPERSEDED)

**Three of my published estimates were wrong. The fitter measured otherwise.**

| Claim (v3/v3.1) | Fitter measurement | Error |
|-----|------|-------|
| VCO ≈ 720 MHz | **360 MHz** (`50 × 36/5`) | 2× overestimate |
| Critical path ≈ 12.3 ns (12 levels) | **39.86 ns** (Fmax 25.09 MHz) | 3.2× underestimate |
| 60 MHz closes with +4.1 ns margin | **60 MHz requires cutting 23.2 ns** | Wrong direction |

**The v3/v3.1 feasibility claim — that a PLL parameter change "dissolves
the feasibility question" — was premature.** Discovering that 20 MHz was
never chosen (which remains true and is a genuine finding) is not the same
as discovering the hardware can exceed it. The design must be able to run
there, and right now, measurably, it cannot.

### What remains true from v3

1. **20 MHz IS the untouched Template_MiSTer default.** Fifth inherited
   ceiling in this project. This finding stands — it was a diff, not an
   estimate.

2. **Decode does NOT need to share `clk_sys` with video.** The coupling
   goes through DDR memory. A separate decode clock leaves video untouched.
   This finding stands — it was traced from RTL.

3. **The CDC cost IS minimal** — 1 async FIFO + ~4 two-FF synchronizers.
   This finding stands — it was traced from the port list.

### What is new in v4

4. **The PLL VCO is 360 MHz** (VERIFIED from STA: `create_generated_clock
   -divide_by 5 -multiply_by 36`). Available 4th outputs: 20, 24, 30, 36,
   40, 45, 60, 72, 90, 120, 180 MHz. **Not all are safe for CDC.**

5. **45 MHz is the only candidate with a safe CDC relationship to clk_ddr.**
   40 MHz has a 2.778 ns worst-case gap (WORSE than the 5.556 ns that failed).
   60 MHz has the SAME 5.556 ns gap. 45 MHz has a 1:2 ratio → edges align
   every cycle → 11.111 ns gap (the full DDR period). See §6A.

6. ~~**The decode fabric currently caps at ~25 MHz**~~ — WRONG (v5). The
   39.86 ns path was in `decode_stub` (dead code). The real fabric limit
   is **UNMEASURED**. All 10 worst clk_sys paths are in `decode_stub`.

7. ~~**The critical path is in the MC simulation model**~~ — WRONG (v5).
   The path is in `decode_stub`, not `h264_luma_qpel_block_16x16`. My
   hypothesis had the right mechanism (massive combinational block) but the
   wrong module.

8. **The `clk_ddr` violating path is a frozen-screen candidate.** (NEW v5)
   `disp_buf_d2 → DDRAM_ADDR[9,15,18,23,...]` — the display buffer bank
   select fails setup timing at -0.213 ns, 7 logic levels, 10.722 ns.
   A bank-select sampled wrong → read from unfilled bank → `has_frame=0`
   forever. This is direct evidence for the bank-race hypothesis (candidate 2).
   w-a3 owns the investigation.

### The honest picture (v5)

- **20 MHz was never chosen** → TRUE (traced)
- **Decode can have its own clock** → TRUE (traced)
- **The fabric caps at 25 MHz** → WRONG (v5, the path was dead code)
- **The fabric's real frequency limit** → UNMEASURED (no fit with real decoder exists)
- **45 MHz is the only safe CDC candidate** → TRUE (computed, unaffected by path identity)
- **45 MHz is achievable** → UNKNOWN (requires a fit with real decode modules)
- **`disp_buf_d2` timing violation may cause frozen screen** → PLAUSIBLE (w-a3 investigating)

The clock question is not answered by v5. It is reframed as: **the fabric
limit has never been measured because every fit so far contained `decode_stub`.
The first fit with real decode modules will produce the first real number.**

Design against **20 MHz / 684 cycles/MB**. "The limit is unknown" is not
"the limit is high."

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

### Recommendation — REVISED v4

**Design to 20 MHz / 684 cycles/MB as the working budget.** Do not loosen
the budget on the strength of a clock increase that has not been demonstrated.

**Simultaneously, prepare for a clock increase to 45 MHz** (1,538 cycles/MB)
by ensuring all decode modules are properly pipelined:

1. **w-mc** replaces the combinational MC simulation model with a
   time-multiplexed implementation (already planned — this is their core
   task). This likely eliminates the 39.86 ns critical path.

2. After the MC replacement lands and a fit runs, **w-cap reports the new
   Fmax**. If the new critical path is ≤22 ns, 45 MHz becomes achievable.

3. **If 45 MHz is achievable:** add 4th PLL output at 45 MHz (VCO=360,
   C=8), convert bitstream_fifo to async, add 2-FF syncs. Budget doubles
   to 1,538 cycles/MB. The 1:2 ratio to clk_ddr gives 11.111 ns worst-case
   CDC gap — the safest relationship short of same-clock.

4. **If 45 MHz is NOT achievable** (critical path >22 ns after MC
   replacement): 684-cycle budget at 20 MHz is the working constraint.
   w-c1's allocation (558/684, 1.23×) stands as the architecture.

| Candidate | Budget | CDC gap vs 90 MHz | Status |
|-----------|--------|-------------------|--------|
| 20 MHz (current) | 684 | 11.111 ns (safe) | **WORKING NUMBER** |
| 30 MHz | 1,026 | 11.111 ns (safe) | Fallback from 45 |
| **45 MHz** | **1,538** | **11.111 ns (safe, 1:2)** | **GOAL (conditional)** |
| 40 MHz | 1,368 | 2.778 ns (**WORSE**) | ~~v3 recommended~~ REJECTED |
| 60 MHz | 2,051 | 5.556 ns (same as failed) | ~~v3.1 recommended~~ REJECTED |

**STATUS: 45 MHz is a GOAL, not a PLAN. The working number is 684 cycles/MB
at 20 MHz until a fit demonstrates otherwise.**

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

### PLL spare output analysis — VERIFIED v4

Cyclone V GPLL VCO range (speed grade 7, I-grade): **600–1300 MHz** (documented).

**VCO = 360 MHz** — VERIFIED from `Plex.sta.rpt` (fitter-generated constraint):
```
create_generated_clock ... -divide_by 5 -multiply_by 36
50 MHz × 36 / 5 = 360 MHz
```

**NOTE: 360 MHz is BELOW the documented GPLL minimum VCO of 600 MHz.**
This may indicate the fitter uses a different PLL sub-block with a lower
VCO range, or that the documented minimum is conservative for this speed
grade. **w-cap should clarify which PLL primitive is in use.**

**Actual output derivation (VERIFIED):**

| Counter | Divisor | Frequency | Formula | Status |
|---------|---------|-----------|---------|--------|
| C0 | 18 | 20.00 MHz | 360/18 | VERIFIED |
| C1 | *varies* | *see SDRAM macro* | 360/C | config-dependent |
| C2 | 4 | 90.00 MHz | 360/4 | VERIFIED |

**Available 4th-output frequencies from VCO=360 MHz with CDC gap analysis:**

| Frequency | C | Budget (cyc/MB) | CDC gap vs 90 MHz | Safe? |
|-----------|---|-----------------|-------------------|-------|
| 180 MHz | 2 | 6,154 | 5.556 ns | ⚠ Same as failed |
| 120 MHz | 3 | 4,103 | 2.778 ns | ✗ WORSE |
| 90 MHz | 4 | 3,077 | — (same clock) | Same domain |
| 72 MHz | 5 | 2,462 | 2.778 ns | ✗ WORSE |
| 60 MHz | 6 | 2,051 | 5.556 ns | ⚠ Same as failed |
| **45 MHz** | **8** | **1,538** | **11.111 ns** | **✓ SAFE (1:2)** |
| 40 MHz | 9 | 1,368 | 2.778 ns | ✗ WORSE |
| 36 MHz | 10 | 1,231 | 5.556 ns | ⚠ Same as failed |
| **30 MHz** | **12** | **1,026** | **11.111 ns** | **✓ SAFE (1:3)** |
| 24 MHz | 15 | 821 | 2.778 ns | ✗ WORSE |
| **20 MHz** | **18** | **684** | **11.111 ns** | **✓ Current** |

**45 MHz is the ONLY candidate that provides more cycles AND a safe CDC
relationship.** The 1:2 exact ratio means edges always align on every
clk_decode cycle — the worst-case gap is the full clk_ddr period (11.111 ns).

**Provenance: VCO = 360 MHz is VERIFIED from fitter STA.
C-counter values are COMPUTED (VCO/C). CDC gaps are COMPUTED from
edge alignment analysis.**

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

### 3.1 Stages present in RTL (provenance: structural trace)

**⚠ CRITICAL CAVEAT (failure #17):** The cycle counts below are traced from
RTL structure — the modules exist and have the stated combinational depth.
**But "exists in RTL" ≠ "verified to produce correct output."** The project's
headline claim of "intra decode bit-exact, 1170/1170" was found to compare
HOST C++ against ffmpeg with ZERO RTL involvement. Actual RTL verification
covers **16 of 76,800 luma pixels (0.021%) and 0% of chroma.** The cycle
model is about timing, not correctness — **these stages may produce wrong
results and still take zero cycles to do it.**

| Stage | Cycles/MB | Type | Provenance |
|-------|-----------|------|------------|
| `parse_cavlc` | 3.2 | Sequential | w-c1 measured on test vector |
| `dequant_idct` | 0 | Combinational | Traced: `h264_dequant4x4` + `h264_idct4x4` are pure wires |
| | | | **⚠ COVERS 4×4 AC ONLY — chroma DC 2×2 Hadamard absent from RTL (#16)** |
| | | | **⚠ RTL correctness UNVERIFIED — 0.021% luma, 0% chroma coverage (#17)** |
| `intra_pred` | 0 | Combinational | Traced: `h264_intra4x4_pred` etc. are pure `always @*` |
| | | | **⚠ RTL correctness UNVERIFIED (#17) — host model is bit-exact, RTL is not tested** |

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
| | | | **⚠ Chroma DC 2×2 Hadamard missing from RTL — ≤1 cycle impact but correctness gap** |
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

### v4: Fitter-measured Fmax — CORRECTIONS

**v3/v3.1 estimated the fabric ceiling at 60–81 MHz. The fitter measured
25.09 MHz.** My estimate was wrong by a factor of 3.2×. Here is why.

**Fitter measurements (VERIFIED from `Plex.sta.rpt`):**

```
clk_sys intra-domain Fmax:   25.09 MHz
  Critical path delay:       39.23 ns (39.86 ns was rounded; precise = 39.227)
  Slack at 20 MHz (50 ns):   +10.15 ns
  **Critical path endpoints:  decode_stub|lat_qp[4] → decode_stub|recon_dbg[5]**
  **ALL 10 worst paths are in decode_stub (diagnostic shim, not the decoder)**
  **DECODE FABRIC LIMIT IS UNMEASURED — the Fmax number measures dead code**

clk_ddr intra-domain Fmax:   88.31 MHz
  Critical path delay:       10.72 ns (precise: 10.722)
  Slack at 90 MHz (11.1 ns): -0.21 ns  ← marginally failing on its own
  **Critical path: ddr_frame_store|disp_buf_d2 → DDRAM_ADDR[9,15,18,23,...]**
  **Bank select → address is the frozen-screen candidate (see below)**
```

**Why the 25 MHz "limit" was wrong:**

The v4 Fmax of 25.09 MHz was a real measurement from a real fitter run.
But the endpoints were in `decode_stub` — a simulation and diagnostic shim
that the real decoder replaces. When decode_stub is removed and real decode
modules are fitted, the 39.86 ns path goes with it. **No fit containing
the actual decode pipeline has ever run**, so the fabric's real frequency
limit is unknown.

My v3.1 estimate of 12 logic levels / 12.3 ns was wrong. The fitter's
39.86 ns was real but measuring the wrong thing. **Both errors went in the
direction of their author's argument** — mine underestimated to support
feasibility, the correction over-constrained to support caution. The honest
position: unknown.

**The `clk_ddr` violating path is architecturally significant:**

```
ddr_frame_store|disp_buf_d2 → DDRAM_ADDR[9] (also [15], [18], [23], ...)
slack: -0.213 ns    data delay: 10.722 ns    7 logic levels
```

`disp_buf_d2` is the **display buffer bank select**. It feeds the DDR address
computation for the display read path and **fails setup timing**. A bank-select
register that violates timing on its way into a memory address is a mechanism
for reading the wrong bank. Our silicon signature — `PLXF` present, `seq=4`,
`has_frame=0`, `ddr_busy=0` — is consistent with the display side reading a
bank the producer has not filled.

This is **direct evidence for candidate 2 (bank race)**. w-a3 owns
investigation. Note: -0.213 ns is marginal and may work across most of the
temperature/voltage range. It is a plausible mechanism, not a smoking gun.

**Fix is cheap:** 7 logic levels at 10.7 ns → one pipeline register stage
brings it under the 11.1 ns DDR period with margin.

**Why my 12-level estimate was wrong (v4 analysis, retained for record):**

My v3.1 analysis estimated 12 logic levels (parse_cavlc, deblock) as the
critical path, at ~12.3 ns. The fitter measured 39.86 ns — **3.2× longer**.
The gap is explained by:

1. **Routing delay.** Logic-level counting accounts for ALM propagation but
   NOT for interconnect routing between ALMs. On Cyclone V, routing delay
   often exceeds logic delay, especially for wide fanout combinational cones.
   My estimate used 1.0 ns/level including routing, but the actual
   routing-to-logic ratio for a 256-output combinational block is much higher.

2. **The current RTL has a massive combinational MC block.** The module
   `h264_luma_qpel_block_16x16` (h264_dpb.sv:357–492) computes **ALL 256
   luma qpel samples in a single `always @*` block.** Each sample's worst
   case (`half_c_at`) chains 6 calls to `hraw_at` (each a 6-tap FIR), then
   applies ANOTHER 6-tap on those results — a **6×6 FIR cascade** with
   **441 input bytes → 256 output samples**, all combinational. Plus 128
   chroma epel samples in another `always @*` block.

   **This is the exact same pattern as w-plane's I16 Plane** before
   pipelining: 256 parallel multiply-add operations in one combinational
   block, producing 55–70 logic levels.

**~~HYPOTHESIS~~: the 39.86 ns critical path goes through the MC simulation
model.** ~~This hypothesis is UNVERIFIED~~. **REFUTED (v5).** w-cap extracted
the endpoints: `decode_stub|lat_qp[4] → decode_stub|recon_dbg[5]`. All 10
worst paths are in `decode_stub`, which is a diagnostic shim the real
decoder replaces. The path disappears when `decode_stub` is removed.

**What this means for 45 MHz:**

The 39.86 ns path is not in the real decode fabric. **The fabric's true
Fmax is UNMEASURED.** To get a real number, a fit containing the actual
decode modules (`h264_stream_path`, `h264_cavlc_parser`, `h264_intra_pred`,
w-mc's new MC, w-deblock's filter) must run.

**Previous scenario table (retained for reference, but the starting point
has changed — it is "unknown" rather than "39.86 ns"):**

| Scenario | Decode fabric Fmax | 45 MHz feasibility |
|----------|-------------------|-------------------|
| Real fabric ≤ 22 ns critical path | ≥ 45 MHz | **Achievable** with CDC work |
| Real fabric 22–30 ns | 33–45 MHz | **Marginal** — may need pipelining |
| Real fabric 30–40 ns | 25–33 MHz | **Difficult** — multiple pipeline stages |
| Real fabric > 40 ns | < 25 MHz | **Not feasible** without major restructuring |

**We will not know which row we are in until the first fit with real modules.**

### 6A. CDC relationship analysis (NEW in v4)

**This section was missing from v3/v3.1 and explains why 40 MHz and 60 MHz
are both rejected.**

When two clocks share the same PLL, the worst-case setup relationship is the
smallest positive gap between their edge sets in the superperiod. This gap
determines how tight the timing constraint is at any clock domain crossing.

**The -2.137 ns STA failure** occurred at a 5.556 ns worst-case gap between
20 MHz and 90 MHz. The data delay was 6.181 ns — exceeding the gap by 0.625 ns
(before clock uncertainty). Any new decode clock that creates a similar or
tighter gap creates the same category of timing challenge at every crossing.

| Candidate | Ratio to 90 MHz | Worst-case gap | vs. 5.556 ns (failed) |
|-----------|----------------|----------------|----------------------|
| 20 MHz | 2:9 | 11.111 ns | 2× better |
| 24 MHz | 4:15 | 2.778 ns | **2× WORSE** |
| 30 MHz | 1:3 | 11.111 ns | 2× better |
| 36 MHz | 2:5 | 5.556 ns | ⚠ Same as failed |
| **40 MHz** | **4:9** | **2.778 ns** | **2× WORSE** |
| **45 MHz** | **1:2** | **11.111 ns** | **2× better** |
| 48 MHz | 8:15 | 2.778 ns | **2× WORSE** |
| **60 MHz** | **2:3** | **5.556 ns** | **⚠ Same as failed** |
| 72 MHz | 4:5 | 2.778 ns | **2× WORSE** |
| 90 MHz | 1:1 | — | Same domain |

**The 1:2 ratio (45 MHz) is special.** Every rising edge of 45 MHz coincides
with a rising edge of 90 MHz. The worst-case gap is the FULL 90 MHz period
(11.111 ns), which is the maximum possible for any non-identical clock.

**40 MHz was v3's recommendation. 60 MHz was v3.1's. Both are rejected.**
40 MHz has a 2.778 ns gap — HALF the budget that already failed. 60 MHz
has the SAME 5.556 ns gap that produced the -2.137 ns failure.

**Lesson:** I evaluated candidate frequencies only by throughput gain and
timing closure margin, without computing their CDC relationships. This
project's defining failure mode is CDC timing, and I recommended walking
straight back into it. The measurement (w-cap's CDC gap analysis) wins
over my estimate (which did not consider it).

---

## 7. Recommendations — REVISED v4

### 7.1 Primary: design to 20 MHz / 684 cycles/MB

**w-c1's allocation (558/684, 1.23× margin) stands as the working
architecture.** Do not loosen any budget on the strength of a clock
increase that has not been demonstrated.

### 7.2 Conditional goal: 45 MHz decode clock (1,538 cycles/MB)

**This is a GOAL, not a PLAN.** It requires two preconditions:

1. **The 39.86 ns critical path must be identified and eliminated.** If it
   is in the MC simulation model (hypothesis, UNVERIFIED), w-mc's replacement
   will eliminate it. If it is elsewhere, it must be found and pipelined.

2. **The post-MC-replacement Fmax must be ≥45 MHz** (critical path ≤22.22 ns).
   This requires a fit. No estimate substitutes.

**If both preconditions are met:**
- Add 4th PLL output at 45 MHz (VCO=360, C=8)
- Convert bitstream_fifo to async_fifo
- Add 2-FF synchronizers for status/control
- Budget: 1,538 cycles/MB (2.25× current)
- CDC gap: 11.111 ns (safest possible, 1:2 ratio)

**If either precondition fails:**
- Stay at 20 MHz / 684 cycles/MB
- w-c1's tight-budget architecture is the plan
- v1–v2 conditions (64-bit DPB, adjacent-MB cache) become mandatory

### 7.3 What does NOT change regardless of clock

The following remain good engineering at any frequency:
1. **64-bit coalesced DPB** — byte-serial (988 cyc) doesn't fit at 20 MHz
2. **Pipelined MC FIR** — the combinational model must be replaced anyway
3. **P_Skip fast path** — zero-MV bypass saves cycles at any frequency
4. **Pipelining discipline** — all modules must limit combinational depth
   to ≤15 levels for 45 MHz headroom (22.2 ns period, ~1.5 ns/level)

### 7.4 Next step: identify the 39.86 ns critical path

**This is the most useful thing I can do right now.** The path is either:

(a) In `h264_luma_qpel_block_16x16` (the combinational MC simulation model)
    → eliminated by w-mc's replacement → clock question reopens on merit

(b) In another module → must be found and pipelined → scope of work unknown

**w-cap has been asked for the specific FROM and TO registers from the
fitter timing reports.** Once identified, the path becomes a target for
the same restructuring technique w-plane applied to I16 Plane.

### 7.5 The `clk_ddr` violation and the frozen screen (UPDATED v5)

**`clk_ddr` sits at -0.213 ns intra-domain slack** (Fmax 88.31 MHz
vs 90 MHz target). The violating path is now identified:

```
ddr_frame_store|disp_buf_d2 → DDRAM_ADDR[9,15,18,23,...]
data delay: 10.722 ns    7 logic levels
```

**This is the display buffer bank select feeding the DDR address
computation.** A setup violation here means the address bits can
be computed from a stale or metastable bank select, potentially
reading from the wrong DDR bank. This directly matches the frozen-screen
signature (`has_frame=0`, `ddr_busy=0`).

w-a3's arbiter move INTO clk_ddr adds logic to this domain and may
worsen the slack. However, the `disp_buf_d2` fix is straightforward:
one pipeline register stage reduces the 7-level path to meet the
11.1 ns DDR period.

---

## 8. Provenance Ledger

| Fact | Source | Confidence |
|------|--------|------------|
| clk_sys = 20 MHz | `pll_0002.v` line 46: `output_clock_frequency0("20.000000 MHz")` | Traced ✓ |
| **20 MHz is Template_MiSTer default, never changed** | `git log --all --follow pll_0002.v`: initial commit `44a4611` identical to Template `c599468` | **Traced ✓ (v3)** |
| **VCO = 360 MHz** | `Plex.sta.rpt`: `create_generated_clock -divide_by 5 -multiply_by 36` → 50×36/5=360 | **VERIFIED (v4)** |
| ~~VCO ≈ 720 MHz~~ | ~~Computed from PLL constraints~~ | **WRONG (v3.1) — corrected v4** |
| ~~Fmax clk_sys = 25.09 MHz (critical path 39.86 ns)~~ | ~~`Plex.sta.rpt` Fmax Summary, intra-domain~~ | **MISLEADING (v5) — path is in decode_stub (dead code)** |
| **clk_sys critical path = decode_stub\|lat_qp[4] → recon_dbg[5]** | w-cap `quartus_sta` intra-domain extraction, all 10 worst paths | **VERIFIED (v5)** |
| **Decode fabric Fmax = UNMEASURED** | No fit with real decode modules exists; decode_stub dominates all 10 paths | **ESTABLISHED (v5)** |
| **clk_ddr critical path = ddr_frame_store\|disp_buf_d2 → DDRAM_ADDR** | w-cap `quartus_sta` intra-domain extraction, all 10 worst paths | **VERIFIED (v5)** |
| **Fmax clk_ddr = 88.31 MHz (critical path 10.72 ns, slack -0.213 ns)** | `Plex.sta.rpt` Fmax Summary, intra-domain | **VERIFIED (v4, endpoints v5)** |
| **disp_buf_d2 → DDRAM_ADDR is frozen-screen candidate** | Bank select failing setup → wrong bank read → has_frame=0 | **HYPOTHESIS (v5)** |
| ~~Critical path = 12 levels (~12.3 ns)~~ | ~~First-principles depth analysis~~ | **WRONG (v3.1) — fitter says 39.86 ns** |
| ~~60 MHz target closes with +4.1 ns margin~~ | ~~Estimate~~ | **WRONG (v3.1) — rejected: same CDC gap as failure** |
| **45 MHz is the only safe CDC candidate** | CDC gap analysis: 1:2 ratio → 11.111 ns gap | **COMPUTED (v4)** |
| **40 MHz has WORSE CDC gap (2.778 ns) than 20 MHz (5.556 ns)** | CDC gap analysis: 4:9 ratio | **COMPUTED (v4)** |
| ~~39.86 ns path likely in h264_luma_qpel_block_16x16~~ | ~~RTL: 256 parallel qpel in `always @*`, 6×6 FIR cascade~~ | **WRONG (v5) — path is in decode_stub** |
| **"intra bit-exact 1170/1170" = HOST vs ffmpeg, no RTL** | w-rel `3dbef6a`: `score_h264_native_frames.cpp:301` calls `reconISlice()` (host C++) not Verilator | **VERIFIED (v5.2, failure #17)** |
| **RTL intra verification = 0.021% luma, 0% chroma** | w-rel: 16/76800 pixels via MB0 pipeline trace only | **VERIFIED (v5.2, failure #17)** |
| **Chroma DC 2×2 Hadamard absent from all 33 RTL files** | w-plane: no Hadamard inverse in any source file | **VERIFIED (v5.1, failure #16)** |
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
| Device = 5CSEBA6U23I7 | `sys/sys.tcl` line 2 | Traced ✓ |
| Speed grade = 7 (slowest) | `sys/sys.tcl` line 5 | Traced ✓ |
| STA failure = -2.137 ns | w-cap `clock_relationship_analysis.md` PATH 1 | Cross-ref ✓ |
| w-c1 total allocation = 558/684 | w-c1 at `f31c61a`, delivered via parent | **Official** |
| MC allocation = 250 cyc/MB | w-c1, conditional on adjacent-MB cache | **Official** |
| Arbiter was on wrong clock | w-a3 `60df5a2`: 17 unsynchronized crossings | Traced ✓ |
| Pulse hazard: 7/10 CAS drops | w-a3 `3c6d1d2`: m1_dout_ready beat conservation test | Traced ✓ |
| **w-plane I16 Plane: 55-70 → ~10/8 levels after pipelining + tree** | w-plane `df21c4a`: balanced tree accumulator, pre-computed products | **Reported (v4)** |
| **w-plane Chroma Plane cy1: ~14 levels (deepest intra path)** | w-plane depth audit | **Reported (v4)** |
| **6-tap FIR shift+add decomposition: ~7 levels** | Symmetry: (a+f)+20(c+d)-5(b+e) | **DERIVED (v3.1, still valid)** |
| **CDC cost for decode-only separation: 1 async FIFO + ~4 2-FF syncs** | Traced from stream_path ports and DDR_FRAME_STORE architecture | **Traced ✓ (v3)** |

---

## 9. Open Questions — UPDATED v5

### Resolved

~~1. VCO frequency~~ → **360 MHz** (VERIFIED from STA).

~~12. WHERE IS THE 39.86 ns CRITICAL PATH?~~ → **RESOLVED (v5).**
`decode_stub|lat_qp[4] → decode_stub|recon_dbg[5]`. All 10 worst paths
are in `decode_stub` (diagnostic shim, not the decoder). The path
disappears when real decode modules are fitted. **The decode fabric's
frequency limit has never been measured.**

### Critical open question (v5)

**13. WHAT IS THE REAL DECODE FABRIC'S Fmax?**

This is the single most important open question. No fit containing
the actual decode pipeline has ever run. `decode_stub` dominates all
10 worst clk_sys paths, masking the real fabric's limit.

**Required:** A fit with real decode modules (h264_stream_path,
h264_cavlc_parser, h264_intra_pred, and at minimum w-mc's MC FSM
and w-deblock's filter) to get the first honest Fmax measurement.

**14. Does `disp_buf_d2 → DDRAM_ADDR` cause the frozen screen?**

The display bank select fails setup timing at -0.213 ns and fans out
to multiple DDRAM_ADDR bits. If sampled wrong, the display side reads
an unfilled bank → `has_frame=0` forever. w-a3 is investigating.

Fix if confirmed: one pipeline register stage (7 levels at 10.7 ns
→ comfortably under 11.1 ns DDR period).

### Remaining from v4

9. **Post-decode-stub Fmax.** When `decode_stub` is removed and real
   decode modules are fitted, what does the intra-domain Fmax become?
   This replaces the previous "post-MC-replacement" question — the
   gate is now broader (first fit with any real decode logic).

10. **clk_ddr intra-domain margin.** At -0.213 ns slack, already
    marginal. w-a3's arbiter move INTO clk_ddr adds logic. The
    `disp_buf_d2` pipeline stage (if added) helps but must be measured.

11. **w-cabac's wider arithmetic impact.** Residual pipeline widened
    from `signed [17:0]` to `signed [21:0]`. Impact unknown until a
    fit with real decode modules measures it.

### Still open from v1–v2

2. **Actual CAVLC worst-case** — 50-cycle allocation needs validation.

3. **DDR arbitration contention** — worst-case latency bounds under
   multi-port contention. At 684 cycles/MB, this must be bounded.

4. **Sub-MB partitions** — impact on MC cycle count within the
   250-cycle allocation.

5. **Stack depth of critical paths.** Once `decode_stub` is removed,
   is there one dominant path or a stack of similarly-timed paths?
   The answer determines how much pipelining work 45 MHz requires.

6. ~~**w-plane I16 Plane cy1 = 18 levels**~~ → **RESOLVED.** w-plane reduced
   cy1 from ~18 to ~10 levels via balanced tree accumulator (`df21c4a`).
   Deepest intra path is now Chroma Plane cy1 at ~14 levels. No intra
   path blocks 45 MHz. **CAUTION:** level counts underestimate fitter delay
   by ~3.2× historically — actual ns pending post-fit STA.

---

## 10. Gate Audit — w-arch Self-Assessment (v5)

**Responding to parent's instrument-integrity directive (failure #16).**

### What is my gate?

This study has no pass/fail test. It is a written analysis whose "gate" is
the set of claims in the Executive Summary and the provenance labels in the
Provenance Ledger. A reader trusts the study if the labels are honest.

### 1. What does my pass/fail assertion literally compare?

**It doesn't.** This study contains no automated assertion. Its claims are
validated by:
- TRACED facts: checked against specific RTL lines (verifiable by re-reading)
- VERIFIED facts: confirmed by fitter output (reproducible by re-running STA)
- ESTIMATED facts: computed from first principles (checkable by arithmetic)
- HYPOTHESIS facts: explicitly labelled as unverified

**The "gate" is the Provenance Ledger (§8).** If a label says VERIFIED, the
fact should be reproducible from the cited source. If it says ESTIMATED, it
should be clearly subordinate to any measurement.

### 2. What does it NOT cover that a reader would assume?

**Four gaps identified:**

**Gap A (CRITICAL, failure #17): The cycle model assumes intra decode works.**
w-rel established that "intra bit-exact 1170/1170" compares HOST C++ against
ffmpeg — no RTL, no Verilator, no FPGA. Actual RTL verification covers
16/76,800 luma pixels (0.021%) and 0% chroma. **The cycle model budgets time
for stages whose correctness is essentially unverified in hardware.** The
model is about timing, not correctness — but a reader of "dequant_idct = 0
cycles, combinational (traced)" might reasonably assume the traced module
produces correct output. It might. We do not know.

**Gap B (failure #16): Chroma DC 2×2 Hadamard absent from RTL.**
w-plane established this. Cycle impact ≤1 cycle/MB. Correctness impact:
wrong chroma for ~50% of skin-tone MBs. The model is right about timing
and wrong about correctness.

**Gap C: The cycle model's weighted average assumes specific MB type ratios.**
"70% P_Skip, 20% P_Motion, 10% Intra" is stated as an assumption (§3.3)
but a reader might take the resulting "215 cycles/MB weighted average"
as more authoritative than it is. Different content produces very different
ratios. An I-frame-only stream (some encoders in low-latency mode) would
be 100% Case C = 335 cycles/MB, still within budget but with different
margin characteristics.

**Gap C: Estimated delays were systematically optimistic.** Three estimates
were wrong in the direction of my argument:
- VCO: 720 (too high, made more outputs seem available)
- Critical path: 12.3 ns (too low, made higher frequencies seem reachable)
- 60 MHz margin: +4.1 ns (positive when it should have been deeply negative)

The pattern is clear enough to be a bias, not bad luck. **Readers should
weight my estimated delays as optimistic by default.** The Provenance
Ledger now marks discredited estimates with strikethrough, but the
systematic direction of the errors should be noted.

### 3. Can my gate fail?

**Not automatically — and that is itself a gap.** There is no script that
re-checks the Provenance Ledger claims against the sources it cites. A
future reader must manually verify each TRACED fact by opening the cited
file and line. This is acceptable for a one-time study but fragile if the
RTL changes.

**What would make it fail:**
- If `pll_0002.v` output_clock_frequency0 is changed from 20 MHz → the
  "never changed" finding becomes stale
- If `stream_path .clk()` wiring changes → the decode-on-clk_sys fact stales
- If the PLL VCO changes in a new fit → the 360 MHz figure stales

**None of these are gated.** The study is a snapshot, not a monitor.

### Summary of this audit

| Item | Status |
|------|--------|
| Provenance labels | Honest — discredited items marked, no false VERIFIED |
| **RTL correctness assumed but unverified** | **GAP (#17) — 0.021% luma, 0% chroma verified in HW** |
| Chroma DC Hadamard | **MISSING from RTL (#16)** — cycle impact negligible, correctness impact severe |
| Delay estimates | Systematically optimistic (3 of 3 wrong in same direction) |
| Automated regression | None — study is a snapshot document |
| Recommendations actionability | Sound — 684 cyc/MB working number confirmed by parent |

**This study is about TIMING, not CORRECTNESS.** It answers "can 684
cycles/MB fit the pipeline stages?" — not "do the pipeline stages produce
the right answer?" Those are independent questions. Failure #17 does not
change the cycle model (the stages exist and have the stated depths). It
changes the confidence that the stages being budgeted are actually working.
A correct-but-slow pipeline is a timing problem. A fast-but-wrong pipeline
is a verification problem. **This project has both, and they are not the same.**

---

*This study is a living document. Update it when measured numbers replace
estimates. Every number has a provenance — keep it that way.*
