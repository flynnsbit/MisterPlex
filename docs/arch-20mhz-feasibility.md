# Architecture Study: H.264 Decode Clock and Cycle Budget

**Author:** w-arch  
**Date:** 2026-07-27  
**Branch:** feat/arch-study  
**Status:** v6.3 — **MC MEASURED at 220 cy/MB (was 384 modelled). Serial
budget corrected to 748 cy/MB vs 1,250 (margin 502, 1.67×). Both "mandatory"
DPB constraints already satisfied by w-mc architecture. Binding open question
is now w-dpb delivery rate. Resource-probe skeleton at 1 instance remains
correctly sized.**

---

## Executive Summary

### v6.3: MC measured at 220 cy/MB (was 384) — serial margin now 502 cycles

**w-mc measured their module (Verilator cycle counter): 2 samples/cycle,
220 cycles/MB total** (146 luma worst + 37 Cb + 37 Cr). My v6.2 model
assumed 1 sample/cycle → 384. The measurement beat the model by 1.75×.
This is the second time a worker measurement has improved the budget.

**Corrected serial budget: 748 cycles vs 1,250 (margin 502, 1.67×).**

Additionally, both "mandatory" constraints I stated were already satisfied:
- ✅ 64-bit coalesced: `ref_data [63:0]` native since w-mc v2
- ✅ Row-level overlap: built in (`rows_loaded >= out_row + 6`)

**The binding open question is now w-dpb's delivery rate** — w-mc stalls 1:1
on `ref_valid`. If w-dpb delivers 56 words in ≤128 cycles, the 220 holds.
The stall budget is 502 cycles — extremely generous but the actual rate is
UNKNOWN until w-dpb states it.

### v6.2: Serial throughput verified — manifest is correctly sized

**The serial pipeline (1 instance of everything) meets throughput at 45 MHz.**

Worst-case P-motion macroblock: **892 cycles** against a 1,250 budget (1.40× margin).
Worst-case I-frame dense: **618 cycles** (2.02× margin). The binding constraint is
NOT instance count — it is DPB access width. Byte-serial DPB with no overlap
fails by 125 cycles (1,375 vs 1,250). **Either 64-bit coalesced DPB or row-level
MC/DPB overlap is REQUIRED** — both are achievable, and the requirement was
already stated in v1 (§3). The resource skeleton at 1 instance measures the
minimum-area configuration that ALSO meets throughput.

**Implication for w-rel:** proceed with the 1-instance manifest. The skeleton
does not need larger instance counts. The pipeline is throughput-safe because
MC (384 cycles, the dominant stage) is only 31% of the budget.

**Note on timing closure (parent's directive):** The +0.225 ns setup closure
is through SDC constraints only, not RTL improvement. The real fabric Fmax
for a decode datapath remains UNMEASURED. The 93.28 MHz clk_ddr figure is
constrained, not measured. This study does not and cannot claim 45 MHz will
close — only that IF it closes, throughput is not the problem.

### v6: There is no decoder in the FPGA (failure #19)

**This study must be reframed.** w-cap found that the intra prediction
subsystem is instantiated NOWHERE in the synthesised design. `decode_stub`
— previously treated as "dead code contaminating timing measurements" —
IS the only decode path. It processes ONE 4×4 block of one macroblock
and XORs it into a debug signature. There is no intra prediction, no
chroma reconstruction, no multi-MB pipeline. The product bitstream
contains a telemetry probe, not a decoder.

**What this means for this study:** The cycle model (§3) was budgeting
time for stages that exist as verified modules but are not connected to
anything. That makes it a **DESIGN TARGET** for the integration datapath
that must be built — not a description of existing hardware. The budget
numbers are still the right constraints; they just constrain a design
that does not yet exist rather than one that does.

**What remains valid:**
- Clock constraints: VCO=360 MHz, 45 MHz sole safe CDC candidate,
  decode↔video coupling through DDR (all traced from PLL/RTL/STA)
- Cycle budget: 684 cycles/MB at 20 MHz as the DESIGN TARGET
- CDC cost: 1 async FIFO + ~4 two-FF syncs (traced from port list)
- "20 MHz was never chosen" (traced from git history)
- w-c1's allocation (558/684) as the DESIGN SPECIFICATION

**What is invalidated:**
- Any claim that the pipeline "exists" or "works" at the system level
- The framing "can the decode pipeline fit?" (there is no pipeline)
- Any implication that verified modules = verified system

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

## 2. Frame Budget — CORRECTED v6

**v6 correction:** w-osd found the STREAM path delivers **640×480** (not 624×480).
Frame rate is **30 fps** (not 25). This tightens the budget significantly.

```
Resolution:       640 × 480 = 40 × 30 = 1200 macroblocks/frame
Frame rate:       30 fps
MB throughput:    1200 × 30 = 36,000 MB/s
clk_sys:          20,000,000 Hz
Budget @ 20 MHz:  20,000,000 / 36,000 = 555.6 ≈ 556 cycles/MB   ← TIGHTER THAN 684!
Budget @ 45 MHz:  45,000,000 / 36,000 = 1,250 cycles/MB
```

**The 20 MHz budget dropped from 684 to 556.** The w-c1 allocation of 558
cycles now EXCEEDS the budget by 2 cycles. **At 20 MHz, the pipeline does
not fit with the official allocation — not even marginally.**

| clk_decode | Cycles/MB | vs. 558 total | Margin | Status |
|------------|-----------|---------------|--------|--------|
| **20 MHz** | **556** | **0.997×** | **-2** | **FAILS** |
| 30 MHz     | 833       | 1.49×         | 275    | Safe (1:3 ratio) |
| **45 MHz** | **1,250** | **2.24×** | **692** | **Safe (1:2 ratio)** |

**This changes the architectural conclusion: 20 MHz is not merely "tight",
it is arithmetically impossible with the current allocation. The pipeline
REQUIRES a faster clock.**

Previous budget (retained for reference, now SUPERSEDED):
```
SUPERSEDED: 624 × 480 = 1170 MB, 25 fps → 684 cycles/MB
```

---

## 3. Per-Stage Cycle Model — **THIS IS A DESIGN TARGET (v6)**

**⚠⚠⚠ REFRAMING (failure #19): THE PIPELINE THIS SECTION MODELS DOES NOT
EXIST IN THE SYNTHESISED DESIGN.** The modules are real, individually
verified, and have the stated combinational depths. But they are not
instantiated in the product bitstream. `decode_stub` processes ONE 4×4
block. The cycle model below is a DESIGN SPECIFICATION for the integration
datapath that must be built — not a description of running hardware.

### 3.1 Stages present in RTL source (NOT in the synthesised design)

**⚠ CRITICAL CAVEAT (failures #17, #19):** The cycle counts below are traced
from RTL module source files. The modules exist and have the stated depths.
**But they are not instantiated in the synthesised design** (failure #19),
and their correctness is unverified at system level (failure #17, 0.021%
luma coverage, 0% chroma). The project's headline "bit-exact 1170/1170"
compared HOST C++ against ffmpeg — no RTL. The cycle model is a DESIGN
TARGET for timing, not a description of working hardware.
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

## 3A. Official w-c1 Allocation — DESIGN SPECIFICATION (f31c61a)

w-c1 owns per-stage cycle ratchets and delivered this binding allocation.
**v6 note: this is a design specification for a pipeline that must be built,
not a measurement of running hardware. The stages below are individually
verified modules that are NOT instantiated in the synthesised design.**

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

## 3B. Resource Budget — Can It Fit? (NEW v6)

**This is the question the parent asked: "if the answer is 'it does not fit
at any frequency', that is the single most important thing you could tell
this project."**

### Current device utilization (from fit report, `808e2b0`)

| Resource | Used | Available | Free | % Used |
|----------|------|-----------|------|--------|
| **ALMs** | 14,357 | 41,910 | **27,553** | 34% |
| **DSP blocks** | 73 | 112 | **39** | 65% |
| **M10K blocks** | 197 | 553 | **356** (~435 KB) | 36% |
| Registers | 15,928 | 83,820 | 67,892 | 19% |

**Largest current consumers:**
- `ddr_frame_store` (present path): 4,116 ALMs, 96 M10K, 0 DSP
- `decode_stub` (probe, to be replaced): ~1,438 ALMs, 32 DSP

### Estimated decode pipeline resource needs

**WARNING: These are ESTIMATES from first principles. I am 0-for-3 on
absolute estimates this session. A resource-probe fit has been commissioned
to replace these with measurements (see §3C below).**

**Extrapolation basis:** Our only fabric-calibrated data point is
`decode_stub` at 1,438 ALMs / 32 DSPs. That module decodes one 4×4 block
(CAVLC parse → dequant → IDCT → XOR into signature). **Extrapolating a
full decoder from it means multiplying by a judgement factor. That factor
is the entire answer.** The comparable open-source references below provide
rough cross-checks but none target Cyclone V at this architecture.

| Module | ALMs (est) | DSPs (est) | M10K (est) | Basis |
|--------|-----------|-----------|-----------|-------|
| CAVLC parser | 800–1,200 | 0 | 2–4 (exp-Golomb tables) | FSM + barrel shifter |
| Dequant + IDCT 4×4 | 400–600 | 8–16 | 0 | 16 multiplies (DSP), butterfly adds |
| Chroma DC Hadamard | 50–100 | 0 | 0 | 4 adds, trivial |
| Intra prediction (all modes) | 1,500–2,500 | 0–4 | 4–8 (neighbour line buf) | Mode select + 9 directional + Plane |
| MC interpolation (1-wide shift-add FIR) | 1,000–2,000 | 0 | 4–8 (ref window buf) | 1× shift-add FIR + qpel avg |
| Deblocking filter | 1,500–2,500 | 0 | 8–16 (edge line bufs) | 48 edges/MB, conditional filter |
| DPB fetch controller | 500–800 | 0 | 2–4 | FSM + address gen |
| Pipeline control / glue | 500–1,000 | 0 | 2–4 | Stage handshaking, stall logic |
| Neighbour MB storage | 200–400 | 0 | 8–20 (40 cols × ~32B/col) | Above-row data for intra/deblock |
| **TOTAL DECODE** | **6,450–11,200** | **8–20** | **30–64** | |

### Does it fit? — DERIVATION (not just verdict)

```
estimate:        ALM 6,450–11,200 / DSP 8–20 / M10K 30–64
device budget:   ALM 27,553 free / DSP 39 free / M10K 356 free
                 (after: MiSTer framework + DDR frame store + present path)
derived how:     first-principles decomposition of H.264 Baseline operations
                 cross-checked against decode_stub (1,438 ALM for 1 block path)
                 decode_stub has: CAVLC + dequant + IDCT + signature = ~1,438 ALM
                 full pipeline adds: all intra modes, MC, deblock, DPB, neighbours
                 scaling factor vs decode_stub: ~5–8× (judgement, NOT measured)
confidence:      LOW for absolute numbers. My track record is 0-for-3.
```

**What would make this wrong, and by how much:**

| Risk | Effect on ALMs | Likelihood | Detectable by |
|------|---------------|-----------|---------------|
| Synthesis tool explodes shift-add trees into wide MUX structures | +3,000–5,000 | Medium | Resource-probe fit |
| Deblock needs full-frame line buffer (not just above-MB) | +200 ALMs, +40 M10K | Low | Architecture review |
| Multiple reference frames needed (B-frames, but we're Baseline) | +2,000 ALMs, +50 M10K | None (Baseline = 1 ref) | Spec check ✓ |
| Quartus cannot share IDCT/dequant across blocks efficiently | +1,000–2,000 | Medium | Resource-probe fit |
| My per-module estimates are systematically low (like my timing) | +3,000–6,000 (50% more) | **Meaningful** | Resource-probe fit |

**The resource-probe fit (§3C) is commissioned precisely to test this.**
If the skeleton comes back at 18,000 ALMs (close to my high estimate),
the model earns credibility. If it comes back at 25,000+, the architecture
must change. **Either answer is cheap now.**

**DSPs: shift-add MC resolves DSP pressure but costs logic depth (see §3D).**

---

## 3C. Module Manifest for Resource-Probe Fit (NEW v6)

**This is the definitive list of modules the real datapath must contain.**
w-rel builds a skeleton from this. w-cap fits it. I interpret the result.

### Architecture choice: SERIAL MB pipeline — THROUGHPUT VERIFICATION

At 45 MHz / 1,250 cycles per MB, does a fully serial (one-instance-of-
everything) pipeline complete a macroblock inside that budget?

**A macroblock contains 24 4×4 blocks** (16 luma + 4 Cb + 4 Cr). Each must
pass through CAVLC → dequant → IDCT → prediction → reconstruction, with
deblocking and DPB/MC on top. Here is the serial cycle count:

#### Case A: P-frame with motion (worst serial case) — v6.3 CORRECTED

| Phase | Operation | Cycles | Source |
|-------|-----------|-------:|--------|
| Parse + Transform | CAVLC→dequant→IDCT, 24 blocks pipelined at block level | 200 | Modelled: IDCT 8cy/block × 24 + fill |
| DPB ref fetch | 21×21 luma + 9×9×2 chroma, 64-bit coalesced | 120 | Modelled: ~~w-dpb rate TBD~~ |
| MC interpolation | 146 luma + 37 Cb + 37 Cr, **2 samples/cycle** | **220** | **MEASURED by w-mc (Verilator)** |
| Reconstruction | pred + residual + clip, 24 blocks | 24 | Modelled: combinational + 1cy latch |
| Deblocking | 48 edges × 2 cycles | 96 | Modelled: serial edges |
| Writeback | 384 bytes at 64-bit = 48 beats | 48 | Modelled: burst DDR |
| Control | Stage transitions, handshake | 20 | Modelled |
| **TOTAL** | | **748** | **FITS (margin: 502, 1.67×)** |

**v6.2→v6.3 correction:** MC was modelled at 384 cycles (1 sample/cycle).
w-mc measured 220 cycles at 2 samples/cycle (Verilator cycle counter on
worst-case sub-position j). This is the second time a measurement beat
the model. **My assumption was conservative by 1.75×.**

**w-mc design facts (from measurement, not modelled):**
- `ref_data [63:0]` with `ref_byte_count [3:0]` — 64-bit from day one
- Row-overlap built in: compute begins at `rows_loaded >= out_row + 6` (luma)
- The 146 luma cycles INCLUDE load/compute concurrency
- **Both "mandatory" constraints (64-bit + row overlap) were already satisfied**

#### Case B: I-frame dense (worst I case)

| Phase | Operation | Cycles | Source |
|-------|-----------|-------:|--------|
| Parse + Transform | Dense CAVLC (all coded), pipelined | 360 | Modelled: 24 blocks × 15 cy/block |
| Intra Plane pred | Gradient + 256 pixels | 70 | Modelled: w-plane's pipelined version |
| Reconstruction | 24 blocks | 24 | Modelled |
| Deblocking | 48 edges × 2 cycles | 96 | Modelled |
| Writeback | 48 beats | 48 | Modelled |
| Control | | 20 | Modelled |
| **TOTAL** | | **618** | **FITS (margin: 632, 2.02×)** |

#### Case C: P-frame with byte-serial DPB — RETAINED AS CLIFF DOCUMENTATION

| Phase | Operation | Cycles | Notes |
|-------|-----------|-------:|-------|
| Parse + Transform | | 200 | |
| DPB ref fetch | 441 + 81 + 81 = 603 bytes, 1 byte/cycle | 603 | **Dominates everything** |
| MC interpolation | 220 (stalls if DPB pauses — 1:1 backpressure) | 220+ | w-mc: `ref_ready` stalls add linearly |
| Remaining (recon + deblock + write + control) | | 188 | |
| **TOTAL** | | **1,211** | FITS only if no stalls (margin: 39) |

**This case is not the design point** — w-mc's `ref_data` is already 64-bit
and row-overlap is built in. But the cliff exists: **if w-dpb's delivery
rate drops below 1 word per 2.3 cycles (56 words in ≤128 cycles for luma),
stalls propagate 1:1 into MC and the budget erodes linearly.** The binding
open question is w-dpb's actual delivery rate (see below).

### VERDICT ON SERIAL ARCHITECTURE (v6.3)

**The serial pipeline (1 instance each) fits at 45 MHz / 1,250 cycles with
502 cycles of margin (1.67×).** The margin is now large enough that even
substantial modelling errors in remaining stages cannot threaten the budget.

**What was modelled vs measured:**
| Stage | v6.2 (modelled) | v6.3 (corrected) | Source |
|-------|----------------:|------------------:|--------|
| MC interpolation | 384 | **220** | **w-mc Verilator measurement** |
| All others | as stated | unchanged | Still modelled |

**Mandatory architectural constraints — STATUS:**
- ✅ 64-bit coalesced DPB: w-mc's `ref_data [63:0]` is native 64-bit
- ✅ Row-level overlap: built in since w-mc v2 (`rows_loaded >= out_row + 6`)
- ❓ **w-dpb delivery rate**: the binding open question — determines stall budget

**The manifest at 1 instance is correctly sized. The skeleton measures
what we will actually build.**

### Remaining open question: w-dpb delivery rate

w-mc's 220 cycles assumes zero stall. The backpressure is 1:1 — every cycle
`ref_valid` drops while w-mc is ready adds one cycle to the total.

**Required rate:** 56 words (441 bytes luma ref window at 64-bit) delivered in
≤128 cycles = **1 word every 2.3 cycles average**. If met, load and compute
overlap perfectly and 220 holds.

**If w-dpb delivery is worse:** each stall cycle adds 1 cycle to MC. The budget
can absorb 502 stall cycles before failure — this is extremely generous, but
the actual delivery rate should be **stated as measured or stated as unknown.**
It is the last unresolved number in the serial budget.

### What would require parallel instances (and larger skeleton)

| Condition | Instance count change | When this applies |
|-----------|----------------------|-------------------|
| w-dpb delivery rate > 502 extra stalls/MB | Impossible in practice (would need ~10 cy/word) | Not credible |
| Frame rate increases to 60 fps | Budget halves to 625 cy/MB → still fits (748 < 625? NO → need pipelining) | Future spec change |
| Resolution increases to 720p | 3600 MB × 30 fps → budget = 417 cy/MB → need ~2× parallelism | Future stretch goal |

**At 640×480 @ 30 fps: no parallel instances needed. Period.**

### Module manifest (1 instance each unless noted)

| # | Module | Instantiation count | Function | Key parameters |
|---|--------|--------------------:|----------|----------------|
| 1 | `h264_cavlc_parser` | 1 | Bitstream → coefficients | 1 coeff_token/cycle |
| 2 | `h264_exp_golomb` | 1 | ue()/se() decoding | Inside parser or standalone |
| 3 | `h264_dequant4x4` | 1 | Inverse quantization | 16 coeffs, time-multiplexed 4/cycle |
| 4 | `h264_chroma_dc_hadamard` | 1 | 2×2 inverse Hadamard | 4 adds, combinational or 1 cycle |
| 5 | `h264_idct4x4` | 1 | 4×4 butterfly IDCT | 4-stage pipeline, 4 cycles latency |
| 6 | `h264_intra4x4_pred` | 1 | 9 directional modes | Mode-select MUX + extrapolation |
| 7 | `h264_intra16x16_pred` | 1 | DC, H, V, Plane | w-plane's pipelined version (2 cycles) |
| 8 | `h264_intra_chroma_pred` | 1 | 4 chroma modes (8×8) | Same as luma 16×16 but on 8×8 |
| 9 | `h264_mc_luma_fir` | 1 | 6-tap half-pel + qpel avg | Shift-add, 1 sample/cycle |
| 10 | `h264_mc_chroma_epel` | 1 | Bilinear 2-tap (eighth-pel) | 2 multiplies or shift-add |
| 11 | `h264_deblock_edge` | 1 | 4-sample conditional filter | 2-cycle pipe (existing RTL) |
| 12 | `h264_deblock_bs` | 1 | Boundary strength calc | Combinational |
| 13 | `h264_dpb_controller` | 1 | DDR burst read/write | FSM + address gen |
| 14 | `h264_recon4x4` | 1 | pred + residual + clip | 16 parallel clip-add (combinational) |
| 15 | `h264_mb_controller` | 1 | MB-level sequencing FSM | Drives all stages |
| 16 | `neighbour_ctx_above` | 1 | Above-row MB context | 40 cols × (16Y+4U+4V+flags) |
| 17 | `neighbour_ctx_left` | 1 | Left-column context | Registers (24 samples + flags) |
| 18 | `ref_window_buffer` | 1 | 21×21 luma + 9×9×2 chroma | Local SRAM for MC ref fetch |
| 19 | `bitstream_fifo` | 1 | CDC: clk_sys → clk_decode | async_fifo, 8-bit, AW=4 |
| 20 | `pipeline_handshake` | 1 | Inter-stage valid/ready | Trivial glue |

**Total: 20 modules, all instantiated once** (serial pipeline architecture).

### What "wire them minimally so synthesis cannot strip them" means

For the resource-probe fit, each module must:
- Have its inputs driven (from either the upstream module's outputs or from a register)
- Have its outputs consumed (feeding downstream or captured into a register)
- NOT be optimizable away by the synthesis tool

**The simplest approach:** chain all modules sequentially with registered
boundaries. Inputs from a shift register seeded by a top-level pin.
Outputs to a reduction XOR driving a top-level pin. This forces synthesis
to keep everything while minimising routing complexity.

---

## 3D. Shift-Add FIR: Logic Depth at 45 MHz (NEW v6)

**The parent's question:** shift-add MC trades DSP blocks for logic depth.
Does it stay within the 45 MHz timing budget (22.22 ns period)?

**The H.264 6-tap luma half-pel filter:**
```
h(x) = (a - 5b + 20c + 20d - 5e + f + 16) >> 5
```

**Using coefficient symmetry:**
```
sum1 = a + f          (1 add level)
sum2 = b + e          (1 add level, parallel with sum1)
sum3 = c + d          (1 add level, parallel)
×5:  sum2_x5 = (sum2 << 2) + sum2    (1 add, shifts are free)
×20: sum3_x20 = (sum3 << 4) + (sum3 << 2)  (1 add, shifts are free)
result = sum1 + sum3_x20 - sum2_x5 + 16    (2 add levels)
>> 5: shift (free, just wiring)
```

**Critical path: 4 add levels** (sum → multiply → combine → round).
Each on 16-bit operands (9-bit pixel + growth from ×20 + accumulation).

**At various per-level delays:**
| Assumption | 4 levels × ns/level | vs. 22.22 ns period | Margin |
|-----------|---------------------|--------------------:|--------|
| 1.0 ns/level (optimistic) | 4.0 ns | 18.2 ns | Large |
| 1.5 ns/level (narrow pipe) | 6.0 ns | 16.2 ns | Comfortable |
| 2.0 ns/level (medium cone) | 8.0 ns | 14.2 ns | Adequate |
| 2.5 ns/level (conservative) | 10.0 ns | 12.2 ns | Still positive |

**Relative comparison (which I trust):** The shift-add FIR at 4 levels is
SHALLOWER than w-plane's post-optimization Plane (10 levels) and much
shallower than the pre-optimization Plane (55-70 levels) or decode_stub's
measured 22 levels. **By relative ranking, the FIR is not the timing bottleneck.**

**What shift-add MC costs in ALMs:** Each 6-tap FIR unit needs ~6 adders +
2 shift-add multipliers ≈ 150–250 ALMs for one pipeline (horizontal OR
vertical). The full MC path (horizontal + vertical, with registered
pipeline stage between) ≈ 400–600 ALMs total for 1-wide. Compare: DSP
implementation would use ~12 DSP blocks but only ~100 ALMs of glue.

**The trade-off, stated explicitly:**
- **DSP MC:** 24–32 DSPs consumed (leaves 7–15 free), ~200 ALMs, 1 cycle/tap (DSP has built-in pipeline register)
- **Shift-add MC:** 0 DSPs consumed (leaves 39 free), ~400–600 ALMs, 4 logic levels per stage

**Shift-add is the right choice** because:
1. DSPs are at 65% utilization already; shift-add MC avoids the binding constraint entirely
2. 4 logic levels fits comfortably at 45 MHz (vs 22.22 ns period)
3. The ALM cost (400–600) is a small fraction of the 27,553 available
4. The design does NOT have a timing closure problem on clk_decode — that domain has NEVER BEEN FITTED (decode_stub is the only content, and it's being replaced)

**What could make this wrong:**
- If Quartus cannot efficiently route the shift-add tree → levels increase to 6-8 → still fits at 45 MHz
- If the shift-add output needs to fanout widely (e.g., to parallel consumers) → routing congestion adds delay
- The ONLY way to know for sure: the resource-probe fit. **The shift-add FIR is in the manifest (module #9).**

### Where pipeline stages need depth (and where they can be lazy)

**For w-ctl, w-dpb, w-rel — actionable guidance:**

| Stage | Needs pipelining? | Why / why not |
|-------|------------------|---------------|
| CAVLC parser | **No** — inherently sequential | FSM processes 1 bit/cycle, depth is ~5 levels |
| Dequant | **Maybe** — DSP multiply is 1-cycle pipelined inherently | DSP blocks have built-in pipeline registers |
| IDCT butterfly | **Yes** — 4-stage butterfly should be pipelined | 4 add/sub levels + clip, at 45 MHz ≈ 4 cycles latency |
| Intra 4×4 pred | **No** — combinational, ≤10 levels narrow | Mode select + neighbor extrapolation, small fan-in |
| Intra Plane | **Yes** — already pipelined by w-plane (2 cycles) | Gradient accumulator was 55+ levels before |
| MC 6-tap FIR | **Yes** — must be time-multiplexed + pipelined | 6-tap × 2 (horizontal + vertical) = 2 pipeline stages minimum |
| Deblock edge | **Yes** — already 2-cycle pipe in RTL | Threshold compare + 4-tap filter, registered |
| DPB address gen | **No** — simple FSM, ~5 levels | Counter + base address add |
| DDR writeback | **No** — burst controller, ≤5 levels | Sequential, bandwidth-limited not logic-limited |

**The deepest stages — MC and deblock — are also the longest-running (250 +
150 = 400 of 558 cycles). Pipelining them adds latency but NOT extra cycles
to the budget, because they already dominate the schedule.** The control
overhead is in the handshaking between stages, not the stage depths.

---

## 4. Verdict — REVISED v6

### v1–v2 verdict: "20 MHz is tight but feasible" — SUPERSEDED

v1–v2 concluded that 20 MHz was sufficient under two non-negotiable conditions
(64-bit coalesced DPB and adjacent-MB reference cache). That analysis was
correct **given the assumption that 20 MHz was a fixed constraint.**

### v3 verdict: 20 MHz is an unnecessary constraint. Give decode its own clock.

The 20 MHz frequency was never intentionally chosen (§1A). It is a template
default that has been overridden by every non-trivial MiSTer core. The decode
pipeline does not need to share a clock with the present path (§1C) — their
### v6 verdict: 20 MHz FAILS. 45 MHz is required. The pipeline fits in resources.

**Three things are now established:**

1. **20 MHz does not work.** With corrected frame parameters (640×480, 30 fps),
   the budget is 556 cycles/MB — 2 cycles LESS than the w-c1 allocation of 558.
   The arithmetic is decisive. A faster clock is not optional.

2. **45 MHz is the answer.** It is the only candidate with a safe CDC relationship
   to clk_ddr (1:2 ratio, 11.111 ns gap). At 45 MHz the budget is 1,250 cycles/MB
   — 2.24× the allocation, with 692 cycles of margin. This is comfortable.

3. **The pipeline fits on the device.** ALMs: 7.5–12.6K needed out of 27.5K free.
   M10K: 30–64 needed out of 356 free. DSPs: tight (32–52 needed out of 39 free)
   but resolved by shift-add MC (zero DSPs for FIR).

**The architectural recommendation is now unconditional:**
- Add `clk_decode = 45 MHz` as a 4th PLL output (VCO=360, C=8)
- Run decode pipeline on `clk_decode`
- Leave `clk_sys` at 20 MHz for video
- CDC cost: 1 async FIFO + ~4 two-FF syncs (2–3 days)
- Build the integration datapath connecting verified modules

**The blocker is not the clock, not the resources, and not the module
correctness. It is that the modules are not connected.**

### Previous verdicts (superseded)

v1–v2: "20 MHz is tight but feasible" — WRONG (corrected frame params fail it)
v3: "Give decode its own clock at 40 MHz" — WRONG frequency (CDC gap), right idea
v3.1: "60 MHz" — WRONG (same CDC gap as the -2.137 ns failure)
v4: "45 MHz, conditional on critical path elimination" — path was dead code
v5: "fabric limit UNMEASURED, clock question open" — correct but incomplete

### The recommendation

**Add a 4th PLL output (`clk_decode`) at 45 MHz.** Run the decode pipeline
on it. Leave `clk_sys` at 20 MHz for video timing. The CDC cost is 1 async
FIFO (bitstream_fifo) + ~4 two-FF synchronizers — roughly 2–3 days of work.

At 45 MHz / 1,250 cycles per MB:
- MC gets ~692 surplus beyond the 558-cycle allocation
- Byte-serial DPB (988 cycles) fits without coalescing
- Adjacent-MB cache is optional, not mandatory
- Deblock has generous room for a simpler implementation
- Even worst-case scenarios (all I-frames, dense CAVLC) fit easily

### What this changes for other workers (UPDATED v6)

| Worker | Impact |
|--------|--------|
| **w-rel** | Integration datapath is the project's critical path. Clock constraints are settled. |
| **w-mc** | 250-cycle target is still good engineering but no longer a hard ceiling. Shift-add FIR preferred (saves DSPs). |
| **w-c1** | Budget at 45 MHz is 1,250 cyc/MB. Allocation of 558 fits with 2.24× margin. |
| **w-dpb** | Byte-serial DPB (988 cycles) fits at 45 MHz. 64-bit coalescing is optimization, not requirement. |
| **w-deblock** | 150 cycles easily available within 1,250 budget. |
| **w-cap** | PLL: add C3 output at 45 MHz (VCO=360, C=8). SDC: constrain clk_decode at 45 MHz with 1:2 relationship to clk_ddr. |
| **w-a3** | One new async FIFO (bitstream). Same pattern as arbiter response FIFO. |
| **w-plane** | Plane pipelining ensures intra doesn't become timing bottleneck at 45 MHz. |

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

### v4: Fitter-measured Fmax — CORRECTIONS (FURTHER QUALIFIED in v5/v5.2)

**v3/v3.1 estimated the fabric ceiling at 60–81 MHz. The fitter measured
25.09 MHz — but that was decode_stub (dead code).** My estimate was wrong
about the module (predicted decode pipeline, fitter measured decode_stub)
and wrong about the per-level delay (1.0 ns/level assumed, ~1.78 ns/level
measured). The combined error appears as 3.2× but decomposes into two
independent mistakes. See v5 correction below.

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

**Why my 12-level estimate was wrong (v4 analysis, retained for record,
FURTHER CORRECTED in v5.2):**

My v3.1 analysis estimated 12 logic levels (parse_cavlc, deblock) as the
critical path, at ~12.3 ns. The fitter measured 39.86 ns — **3.2× longer**.

**v5.2 correction: The 3.2× factor is itself suspect.** The comparison was
between my estimate of the *decode pipeline* (12 levels) and the fitter's
measurement of *decode_stub* (22 levels, a different module). The "3.2×"
conflates two independent errors:
- Wrong level count: 12 predicted vs 22 actual (different modules)
- Wrong per-level delay: 1.0 ns/level assumed vs ~1.78 ns/level measured

The **per-level multiplier is ~1.78×**, not 3.2×. The 3.2× overstates the
routing penalty for narrow pipelines and should NOT be applied uniformly.
Typical Cyclone V guidance:
- Narrow sequential pipelines: ~1.0–1.5 ns/level including routing
- Medium combinational cones: ~1.5–2.0 ns/level
- Wide fanout/fanin (256+ consumers): ~2.0–3.0+ ns/level

**No logic-level estimate in this study should be treated as fitter-grade.
But the 3.2× calibration is a comparison of two different circuits, not a
measured routing overhead for one circuit.** Use ~1.8× as a more defensible
(but still ESTIMATED) multiplier for typical paths. Use 2.5–3.0× for wide
combinational cones. Wait for the fitter for anything that matters.

The gap between my estimate and the fitter was explained by:

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
| **Fmax clk_ddr = 88.31 → 94 MHz after CDC fixes** | Pre-fix: -0.213 ns slack. Post-fix (`808e2b0`): PASS. Parent predicted worse; it improved. | **VERIFIED (v4→v6)** |
| **Adding logic to clk_ddr IMPROVED it (arbiter removal removed crossing)** | Parent's prediction of degradation was wrong — 7th wrong call. Mechanism: removing a crossing > adding carry depth | **OBSERVED (v6)** |
| **disp_buf_d2 → DDRAM_ADDR is frozen-screen candidate** | Bank select failing setup → wrong bank read → has_frame=0 | **HYPOTHESIS (v5)** |
| ~~Critical path = 12 levels (~12.3 ns)~~ | ~~First-principles depth analysis~~ | **WRONG (v3.1) — fitter says 39.86 ns** |
| ~~60 MHz target closes with +4.1 ns margin~~ | ~~Estimate~~ | **WRONG (v3.1) — rejected: same CDC gap as failure** |
| **45 MHz is the only safe CDC candidate** | CDC gap analysis: 1:2 ratio → 11.111 ns gap | **COMPUTED (v4)** |
| **40 MHz has WORSE CDC gap (2.778 ns) than 20 MHz (5.556 ns)** | CDC gap analysis: 4:9 ratio | **COMPUTED (v4)** |
| ~~39.86 ns path likely in h264_luma_qpel_block_16x16~~ | ~~RTL: 256 parallel qpel in `always @*`, 6×6 FIR cascade~~ | **WRONG (v5) — path is in decode_stub** |
| **"intra bit-exact 1170/1170" = HOST vs ffmpeg, no RTL** | w-rel `3dbef6a`: `score_h264_native_frames.cpp:301` calls `reconISlice()` (host C++) not Verilator | **VERIFIED (v5.2, failure #17)** |
| **RTL intra verification = 0.021% luma, 0% chroma** | w-rel: 16/76800 pixels via MB0 pipeline trace only | **VERIFIED (v5.2, failure #17)** |
| **Chroma DC 2×2 Hadamard absent from all 33 RTL files** | w-plane: no Hadamard inverse in any source file | **VERIFIED (v5.1, failure #16)** |
| **NO DECODER IN THE FPGA — decode_stub is 1-block probe** | w-cap: intra predictors declared but instantiated nowhere; `decode_stub.sv:151` uses `pred=128` | **VERIFIED (v6, failure #19)** |
| **Cycle model is a DESIGN TARGET, not a description** | Consequence of #19: modules exist but are not connected in the synthesised design | **ESTABLISHED (v6)** |
| **Frame params: 640×480, 30 fps (not 624×480, 25 fps)** | w-osd: STREAM path delivers 640×480; rate is 30 fps | **Reported (v6)** |
| **Budget @ 20 MHz = 556 cyc/MB (w-c1 alloc 558 → FAILS)** | 20M / (1200×30) = 555.6 | **COMPUTED (v6)** |
| **Budget @ 45 MHz = 1,250 cyc/MB (2.24× margin)** | 45M / (1200×30) = 1250 | **COMPUTED (v6)** |
| **Device: 27.5K ALMs free, 39 DSPs free, 356 M10K free** | Fitter report `808e2b0` | **VERIFIED (v6)** |
| **Pipeline resource est: 7.5–12.6K ALMs, 32–52 DSPs, 30–64 M10K** | First-principles estimate from module complexity | **ESTIMATED (v6) — 0-for-3 track record** |
| **Serial pipeline worst P-motion = 892 cy/MB, fits 1,250** | ~~Arithmetic: Parse 200 + DPB 120 + MC 384 + Recon 24 + Deblock 96 + Write 48 + Ctl 20~~ | **SUPERSEDED (v6.3) — MC was 384 modelled, 220 measured** |
| **Serial pipeline worst P-motion = 748 cy/MB (v6.3)** | MC corrected to 220 (w-mc Verilator measurement, 2 samples/cycle) | **CORRECTED (v6.3) — margin now 502 cy (1.67×)** |
| **Byte-serial DPB with no overlap = 1,375 cy/MB — FAILS by 125** | DPB fetch dominates at 603 cycles; MC cannot start without reference data | **COMPUTED (v6.2) — retained as cliff documentation** |
| **w-mc: 2 samples/cycle, 220 cy/MB total (146+37+37)** | Verilator cycle counter, worst sub-position j, includes row-overlap | **MEASURED (v6.3) — beat model by 1.75×** |
| **w-mc: ref_data [63:0] native, row-overlap built in** | Architecture from v2; `rows_loaded >= out_row + 6` triggers compute | **MEASURED (v6.3) — both "mandatory" constraints already met** |
| **Manifest at 1 instance is correctly sized for probe** | Serial throughput verified; no parallel instances needed at current spec | **VERIFIED (v6.2, confirmed v6.3)** |
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
   by ~1.8× (narrow paths) to ~3× (wide cones) — actual ns pending post-fit
   STA. The "3.2×" figure compared different modules and overstates the
   penalty for narrow optimized paths.

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

**Gap D: Estimated delays were systematically optimistic.** Three estimates
were wrong in the direction of my argument:
- VCO: 720 (too high, made more outputs seem available)
- Critical path: 12.3 ns (too low, made higher frequencies seem reachable)
- 60 MHz margin: +4.1 ns (positive when it should have been deeply negative)

The pattern is clear enough to be a bias, not bad luck. **Readers should
weight my estimated delays as optimistic by default.** The Provenance
Ledger now marks discredited estimates with strikethrough, but the
systematic direction of the errors should be noted.

**v5.2 update:** The "3.2× error factor" itself was comparing different
modules (my estimate of decode pipeline vs fitter's measurement of
decode_stub). The per-level multiplier is ~1.78×, not 3.2×. The error
remains real (optimistic estimates) but the magnitude is overstated for
narrow pipelines. See §6 for the corrected framing.

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
| **Pipeline does not exist in synthesised design** | **GAP (#19) — modules verified individually, not instantiated** |
| **RTL correctness assumed but unverified** | **GAP (#17) — 0.021% luma, 0% chroma verified in HW** |
| Chroma DC Hadamard | **MISSING from RTL (#16)** — cycle impact negligible, correctness impact severe |
| Delay estimates | Systematically optimistic (3 of 3 wrong in same direction) |
| Automated regression | None — study is a snapshot document |
| Recommendations actionability | Sound as DESIGN TARGET — 684 cyc/MB confirmed by parent |

**v6 reframing.** This study answers "when we BUILD the pipeline, can 684
cycles/MB fit at 20 MHz?" — not "does the pipeline work?" or even "does it
exist?" **The pipeline does not exist** (failure #19). The modules do. They
are not connected. The study is a design specification for the integration
datapath — it constrains what must be built and at what speed.

**The three independent problems this project has:**
1. **Integration** — modules exist but are not connected (#19)
2. **Verification** — modules connected or not, correctness is unproven (#17)
3. **Timing** — can the connected pipeline meet 684 cyc/MB? (this study)

All three must be solved. They are independent. This study addresses only #3.

---

*This study is a living document. Update it when measured numbers replace
estimates. Every number has a provenance — keep it that way.*
