# Decode throughput budget — DESIGN TARGET, not a pipeline measurement

**Critical context (#19, 2026-07-27):** There is **no decode pipeline in the
FPGA**. `decode_stub.sv` is a telemetry probe that processes one 4×4 block
(dequant + IDCT, `pred=128` constant, XOR into `recon_sig`). Intra prediction
modules exist and are tested at module level but are **instantiated nowhere
in the synthesised design**. This document describes a **cycle budget for a
pipeline that does not yet exist** — a design target, not a description.

**Instrument-integrity note (2026-07-27):** This gate tests the **checker
logic** (`check_decode_throughput.py`), not the simulation. The test input
is a synthetic JSON with hardcoded cycle counts. The actual Verilator sim is
run by `test_stream_path_full_frame_compare.sh` (a separate gate). The
`effective_fps` headline (65.9) is 98.7% diagnostic paint — it measures the
diagnostic pixel-painting rate of `decode_stub`, not a decode pipeline.

**What is in the product bitstream:**
```
parse → extract residual → dequant + IDCT (ONE 4×4 block) → XOR into recon_sig
```
That is a probe, not a decoder. Everything in this document is either:
- Measuring the probe's cycle behaviour (valid as timing of the probe)
- Budgeting for a future pipeline (valid as a design target)

Neither should be confused with measuring a decoder's throughput.

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
| Target frame rate | **30 fps** (worst-case) | PMS can deliver up to 30 fps; `Plex.sv:231` hardcodes `content_fps=24` but content varies |
| 480p coded geometry | **624×480 = 39×30 MBs = 1170 MB/frame** | SPS parser output from test streams; `decode_stub.sv:194` hardcodes `width=624, height=480` |
| Display geometry | 640×480 (40×30 = 1200 MBs) | VGA scanout with 11px pillars; **NOT the coded frame** |
| `stream_path` clock | 20.000 MHz | `pll_0002.v` `outclk_0`; `Plex.sv` connects `stream_path.clk(clk_sys)` |
| SDRAM clock | selectable, default 100 MHz; `SDRAM_CLK_142` makes `clk_sdram` 142 MHz | `Plex.sv`/PLL |

### Frame geometry clarification (responding to w-arch v6, 2026-07-27)

**w-arch claims the stream delivers 640×480 at 30 fps. This conflates the DISPLAY
frame with the CODED frame.**

The decode budget is based on the **coded** macroblock count — that is, what the
H.264 decoder actually processes:

- **Coded frame:** 624×480 (39×30 = **1170 MBs**) — from PMS transcoder, confirmed in
  every test bitstream filename, SPS parser output, `decode_stub.sv:194`, and
  `scripts/capture_baseline_annexb_fixture.sh` (`plex_real_baseline_624x480`)
- **Display (crop):** 618×480 — SPS frame_cropping_rect_right_offset removes 6px
- **Presented (VGA):** 640×480 — 11px black pillars each side, purely scanout

The decoder processes 1170 MBs (coded), not 1200 (display). w-arch's claim that
"the STREAM path delivers 640×480" confuses the VGA output dimension with the
H.264 bitstream dimension. **The encoder decides the coded frame size, not the
display.**

However, w-arch's **30 fps** claim deserves conservative adoption:
- `Plex.sv:231` hardcodes `content_fps = 8'd24`
- PMS can transcode at 23.976/24/25/29.97/30 fps depending on source content
- The budget must handle worst-case content → **30 fps adopted**

### Budget arithmetic (CORRECTED for 30 fps, 2026-07-27)

The decode pipeline is clocked by `clk_sys`, not `clk_sdram`. With 30 fps
worst-case:

```
1170 MB/frame × 30 fps = 35,100 MB/s
20,000,000 cycles/s ÷ 30 fps = 666,667 cycles/frame
666,667 cycles/frame ÷ 1170 MB/frame = 569.8 cycles/MB
```

Previous budget (at 25 fps): 684 cycles/MB.
**Revised budget (at 30 fps): 570 cycles/MB.** This tightens the margin from
1.23× to 1.02× — essentially zero margin for error.

| Frame rate | Budget cycles/MB | Margin at 558 total | Assessment |
| ---:| ---:| ---:| --- |
| 24 fps (`content_fps` RTL) | 712 | 1.28× | Comfortable at one frame rate |
| 25 fps (previous) | 684 | 1.23× | Old budget |
| **30 fps (worst-case)** | **570** | **1.02×** | **12 cycles of headroom — CRITICAL** |

**20 MHz is MARGINAL for 30 fps content.** Not arithmetically impossible (w-arch's
"exceeds by 2 cycles" used 1200 MBs / 640×480 which is wrong), but so tight that
any estimate overrun breaks it. At 30 fps + 20 MHz: MC can only reach **262
cycles/MB** before the budget breaks. The current MC estimate of 250 has **12
cycles of headroom.** That is not a design margin, it is an error bar.

**45 MHz makes this problem disappear:**
```
45,000,000 / (1170 × 30) = 1,282 cycles/MB    → margin 2.30× at 558 total
```

**The architectural conclusion:** 45 MHz is now STRONGLY RECOMMENDED (not strictly
mandatory as w-arch claimed, because the coded frame is 624 not 640, giving 12
more cycles). But a 12-cycle margin is engineering zero. Any practical design
should target 45 MHz.

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

**#19 context: these measurements are of `decode_stub`, a telemetry probe.**
`decode_stub.sv` processes ONE 4×4 block (dequant + IDCT, pred=128 constant),
then paints W×H diagnostic pixels at 1 px/cycle. There is no intra prediction,
no chroma reconstruction, no multi-MB pipeline. The "per-stage" measurements
below are timing of the probe, not of a decode pipeline.

The aggregate 259 cycles/MB was **98.7% decode_stub diagnostic paint overhead**.
Per-stage instrumentation (via `stub_busy`/`fs_wr_reset`/`fs_swap` phase
transitions in the Verilator testbench) reveals the breakdown of the **probe**:

| Stage | cycles/MB | Status | Method |
| --- | ---:| --- | --- |
| parse_cavlc | 3.2 | **measured [RTL probe]** | stub_busy rise → fs_wr_reset transition |
| dequant_idct | 0 | **measured [RTL probe]** | combinational (one 4×4 block only) |
| intra_pred | 0 | **N/A — not instantiated** | `decode_stub:151` uses `pred=128` constant |
| diagnostic_paint | 256 | measured, **NOT PRODUCTION** | fs_wr_reset → fs_swap; WxH pixels at 1 px/cycle |
| mc_interpolation | **?** | **NOT INSTANTIATED** | modules exist, not in synthesised design |
| deblock | **?** | **NOT INSTANTIATED** | modules exist, not in synthesised design |
| ddr_write | **?** | **NOT INSTANTIATED** | ddr_frame_store writes diagnostic pixels only |
| injection_overhead | 10 | measured, **TESTBENCH ARTIFACT** | ioctl 2 cycles/byte; product uses DDR DMA |

**What "MARGINAL 2.20x" actually measured (was 2.64× at 25 fps):** the ratio of
the realtime budget (570 cycles/MB at 30 fps) to the aggregate cycle count (259
cycles/MB), where the aggregate is dominated by decode_stub painting 624×480
diagnostic pixels per frame — an operation that does not exist in the production
decoder. The three most expensive production stages (MC, deblock, DDR write)
contribute exactly **zero measured cycles** because they are not built yet. The
margin is **illusory** and will collapse when those stages are implemented.

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

At 35,100 MB/s (30 fps):

```
987 B/MB × 35,100 MB/s = 34,643,700 B/s = 34.64 MB/s
```

The display frame store also consumes one 624×480 I420 frame per presented
frame:

```
624×480×1.5×30 = 13,478,400 B/s = 13.48 MB/s
```

The 624×480 12-frame fixture is 70,348 bytes, or 175,870 B/s at 30 fps. Even
doubling that for compressed bitstream write/read is less than 0.35 MB/s.

Known modelled traffic is therefore about **48.5 MB/s** before refresh/arbitration
losses. Raw bandwidth should be enough, but this is not a pass: the bitstream
reader, DPB, and frame store contend for the same `DDRAM_*` path, and the live
PLXF-missing fault means arbitration/liveness remains a first-class risk.

## Per-stage budget allocation — DESIGN TARGET (revised 2026-07-27, v3)

**Owner: w-c1. This is a DESIGN TARGET for a pipeline that does not yet exist.**
Every line is labelled MEASURED, ESTIMATED, EXTRAPOLATED, or ALLOWANCE. None of
the stages below (except parse) are instantiated in the synthesised design (#19).

**⚠ CLOCK CONSTRAINT STATUS:** The 570 cycles/MB budget assumes `clk_sys` =
20 MHz at 30 fps worst-case. The fabric frequency limit is **UNMEASURED** (the only Fmax figure was
from `decode_stub` dead code). 20 MHz is the Template_MiSTer default that was
never chosen. Decode can be clock-separated from video via a 4th PLL output, but
reaching 45 MHz (the only safe CDC candidate) requires ~17.6 ns of critical-path
reduction from the production pipeline — which does not exist yet to measure.
**The ratchet retains 20 MHz until a production-pipeline fit reports otherwise.**

Total budget: **570 cycles/MB** at 20 MHz / 30 fps / 1170 MB per frame (worst-case).
Previous: 684 cycles/MB at 25 fps. The 30 fps worst-case tightens the design constraint.

| Stage | Allocated | Label | Constraint | Reasoning |
| --- | ---:| --- | --- | --- |
| parse_cavlc (full) | 50 | **ESTIMATED** | MANDATORY at 20 MHz, optional at ≥40 MHz | MEASURED 3.2 is for a stub. Production full-MB CAVLC is unmeasured. |
| dequant_idct | 48 | **ESTIMATED** | MANDATORY at 20 MHz, optional at ≥40 MHz | MEASURED 0 (combinational). 24 blocks × 2 cycles when clocked. |
| intra_pred | 30 | **ALLOWANCE** | RECOMMENDED | MEASURED 0 (DC only). All-Plane I-frames spike to ~70. |
| **mc_interpolation** | **250** | **ESTIMATED** | **MANDATORY at 20 MHz** — overlap exploit required. **RECOMMENDED at ≥40 MHz** — straightforward design suffices. | Unbuilt. 21×21 qpel ref + DDR fetch + interpolation. |
| **deblock** | **100** | **EXTRAPOLATED from measurement** | MANDATORY at 20 MHz, optional at ≥40 MHz | w-deblock measured 56 cycles for 24 internal luma segments (2 cycles/segment, register-file gather/scatter). 48 total segments extrapolates to ~96. Rounded to 100. |
| ddr_write | 50 | **ESTIMATED** | MANDATORY at 20 MHz, optional at ≥40 MHz | 48 coalesced 64-bit beats + arbitration. |
| control_overhead | 30 | **ALLOWANCE** | RECOMMENDED | Pipeline stalls, MB bookkeeping. Placeholder. |
| **TOTAL** | **558** | | | |
| **Remaining margin** | **12** | | | **1.02× at 20 MHz / 30 fps; 2.30× at 45 MHz** |

**⚠ CRITICAL:** At 30 fps, the margin at 20 MHz has collapsed from 126 cycles
to **12 cycles**. This is engineering zero. MC is allocated 250 but can only
reach **262** before the budget breaks. Any overrun in any stage kills realtime.
**45 MHz is the only safe operating point for production.**

### Adjacent-MB reference overlap

At 20 MHz / 30 fps (570 budget): overlap exploitation is **MANDATORY** — without
it, the MC breaking point is only 262 cycles/MB (non-MC stages sum to 308).
That is 12 cycles above the estimate. Any overrun fails.

With overlap (~100 cycles saved from MC): MC allocation drops to ~150, total
to ~458, margin to 1.24× (112 cycles). Still tight but survivable.

At 45 MHz (1,282 budget): overlap is **nice-to-have** — the budget has 2.30×
margin and a straightforward MC design fits trivially.

**Adjacent-MB overlap exploitation is now a REQUIREMENT at 20 MHz, not a recommendation.**

### What this excludes

- **Intra_16x16 Plane mode** (w-plane added combinational RTL; budget impact is in intra_pred allowance)
- **I_PCM** (not implemented in RTL)
- Arbitration contention from display reads (frame_store consumer)
- Content variation (high-motion P-frames with sub-MB partitions)
- w-a3's m1 response async FIFO latency (added at `3c6d1d2`)
- w-cabac's `signed [21:0]` widening (longer carry chains may affect timing at higher clocks)
- CABAC (not relevant — Baseline profile uses CAVLC only)

## Sensitivity analysis (updated for 30 fps worst-case)

The 1.02× margin rests on estimates for two unbuilt stages (MC 250 + DDR write
50 = 300 cycles) and one extrapolated (deblock 100). This section states the
breaking points **at 20 MHz / 30 fps**. At 45 MHz, none of these scenarios are
binding.

### MC breaking point

Non-MC stages sum to 308 cycles/MB. The budget breaks when MC exceeds:

```
570 − 308 = 262 cycles/MB    ← MC breaking point at 20 MHz / 30 fps
```

The current MC estimate is 250. That is **12 cycles of headroom** — effectively
an error bar, not a design margin. **Any MC overrun at 20 MHz / 30 fps breaks
realtime.**

For comparison, at 25 fps the breaking point was 376 cycles/MB (126 headroom).
The 30 fps correction removed 80% of the MC headroom.

### 50% overrun on all unbuilt stages

| Stage | Base | +50% |
| --- | ---:| ---:|
| mc_interpolation | 250 | 375 |
| deblock | 100 | 150 |
| ddr_write | 50 | 75 |
| Subtotal | 400 | 600 |
| + other stages | 158 | 158 |
| **Total** | **558** | **758** |
| vs 570 budget (20 MHz/30fps) | **1.02× BARELY** | **0.75× FAILS HARD** |
| vs 1282 budget (45 MHz) | 2.30× OK | 1.69× OK |

### Scenario table

| Scenario | MC | Deblock | Total | Margin (20 MHz/30fps) | Margin (45 MHz) |
| --- | ---:| ---:| ---:| ---:| ---:|
| Base estimate | 250 | 100 | 558 | 1.02× CRITICAL | 2.30× OK |
| MC with overlap | 150 | 100 | 458 | 1.24× tight | 2.80× OK |
| MC overruns 5% | 263 | 100 | 571 | **1.00× BREAKS** | 2.25× OK |
| All unbuilt +50% | 375 | 150 | 758 | 0.75× **FAILS** | 1.69× OK |
| MC at 300 | 300 | 100 | 608 | 0.94× **FAILS** | 2.11× OK |

**Key observation:** at 30 fps, the 20 MHz budget breaks with a mere **5% MC
overrun** (13 extra cycles). Every scenario except base and overlap FAILS at 20
MHz. The clock is not just a preference — **45 MHz is arithmetically required
for any realistic design margin.**

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

## Clock provenance investigation (2026-07-27)

**Finding: 20 MHz is the Template_MiSTer default. It was never chosen.**

### Evidence

1. **Template comparison:** `MiSTer-devel/Template_MiSTer` ships with
   `pll_0002.v` `outclk_0 = 20.0 MHz`. Our `pll_0002.v` was created at commit
   `44a4611` ("Phase 0/1: scaffold MiSTerPlex monorepo and native present
   core") — a template import. **`outclk_0` has never been changed from the
   template default.** Git log on `pll_0002.v` shows 6 commits; only `outclk_1`
   (SDRAM) and `outclk_2` (DDR bridge) were ever modified.

2. **Pattern recognition:** This is the fifth inherited default that was treated
   as a design constraint:
   - SDRAM "pinned at 100 MHz" → was the `else` branch fallback; runs at 142 MHz
   - `DDRAM_CLK` "at 20 MHz" → was the legacy template default; now 90 MHz
   - Baseline profile "impossible" → 11 client-side attempts; 1 server-side fix
   - Timing "cannot close at -2.137 ns" → was an arbiter on the wrong clock domain
   - **`clk_sys` at 20 MHz → template default, never revisited**

3. **What `clk_sys` feeds** (traced from `Plex.sv`):
   - `hps_io` (line 128) — HPS bridge
   - `ddram_frame_rd` (line 491) — DDR frame reader
   - `stream_path` (line 588) — **THE DECODE PIPELINE**
   - `present_core` (line 705) — video output timing, generates `ce_pix`
   - `ddr_bus_arbiter` (line 784) — DDR bus arbiter
   - `CLK_VIDEO = clk_sys` (line 817) — **VIDEO OUTPUT CLOCK**
   - Various `always @(posedge clk_sys)` blocks for status, LED, debug

4. **Critical coupling:** `CLK_VIDEO = clk_sys` means the decode clock IS the
   video output clock. `sys_top.v` assigns `clk_vid = CLK_VIDEO`, which drives
   `hdmi_tx_clk` and the `ascal` input. **However**, the MiSTer framework's
   `ascal` (hardware scaler) can rescale from any input pixel rate to the
   output display rate. Additionally, `ce_pix` divides by 2 in non-scandoubled
   mode, so the effective pixel rate is **10 MHz**, not 20 MHz. The 20 MHz
   clock has headroom even in its video timing role.

5. **Separation path:** `pll_0002.v` already produces 3 independent outputs
   (C0=20 MHz, C1=142 MHz, C2=90 MHz). A fourth output at 40/60/90 MHz for
   a dedicated `clk_decode` costs nothing in PLL resources. `stream_path`
   would take `.clk(clk_decode)` instead of `.clk(clk_sys)`, and
   `present_core`/`CLK_VIDEO` stay on `clk_sys`. The only CDC needed is the
   frame-store handoff (already crosses domains via `fs_swap`/`fs_wr_reset`).

### Clock upside — what is real vs what was premature (CORRECTED ×2, 2026-07-27)

**The provenance finding stands:** 20 MHz is genuinely an untouched
Template_MiSTer default that nobody chose. The separation path (4th PLL output
for decode, video stays on `clk_sys`) is architecturally clean.

**The fabric frequency limit is UNMEASURED.** Two successive corrections:

1. w-arch estimated the critical path at 12 logic levels ≈ 12.3 ns →
   theoretical 81 MHz. **Refuted by fitter:** measured 39.86 ns (3.2× longer
   because routing delay was excluded).
2. w-cap measured fitter Fmax at 25.09 MHz (39.86 ns critical path). **Then
   identified the endpoints:** `decode_stub|lat_qp[4]` → `decode_stub|recon_dbg[5]`,
   22 logic levels. **`decode_stub` is a diagnostic shim, not the decoder.**
   All 10 worst intra-domain paths are the same FROM/TO pair. When `decode_stub`
   is replaced by the production decoder, this path disappears and the true
   constraint becomes whatever is second-deepest — which is also `decode_stub`.

**We have no measurement of the real decode fabric's frequency limit.** Not from
w-arch's estimate, not from the 25.09 MHz figure. It requires a fit containing
production decode modules, and that fit has not run.

#### Cross-domain timing relationships (from w-cap — UNAFFECTED by decode_stub)

The cross-domain relationship to `clk_ddr` (90 MHz) constrains which decode
frequencies are safe regardless of fabric Fmax:

| Decode clock | DDR ratio | Worst-case setup | Assessment |
| ---:| ---:| ---:| --- |
| 20 MHz (current) | 2:9 | 11.111 ns | Current, working |
| 40 MHz | 4:9 | 2.778 ns | HALF the budget that already failed at -2.137 ns |
| **45 MHz** | **1:2 exact** | **11.111 ns** | **Edges align every cycle — safest** |
| 60 MHz | 2:3 | 5.556 ns | SAME zone that produced the -2.137 ns failure |

**45 MHz remains the only comfortable candidate** if the fabric can reach it.

#### PLL VCO constraint (VERIFIED from STA)

w-cap verified the PLL VCO from `Plex.sta.rpt`:
```
create_generated_clock ... -divide_by 5 -multiply_by 36 ...
```
50 MHz × 36 / 5 = **360 MHz** VCO (not 720 or 1260 as w-arch estimated).
Corroborated by `fractional_vco_multiplier = "false"` in `pll_0002.v`.

#### What a clock increase requires

1. A fit with production decode modules (not `decode_stub`) to learn the real Fmax
2. If Fmax ≥ 45 MHz: a PLL change to 45 MHz (integer ratio to clk_ddr)
3. If Fmax < 45 MHz: identify and pipeline the critical path, then re-fit
4. Verify cross-domain timing closes with the 1:2 ratio

**Until step 1 happens, the frequency limit is unknown. "Unknown" is not
"high" — do not budget against it.**

#### `clk_ddr` violation: `disp_buf_d2 → DDRAM_ADDR` (REAL, PRODUCT PATH)

While the `clk_sys` critical path is diagnostic dead code, the `clk_ddr`
violation is real:
```
FROM:   ddr_frame_store|disp_buf_d2
TO:     ddr_frame_store|DDRAM_ADDR[9] (also [15], [18], [23], ...)
slack:  -0.213 ns    7 logic levels    10.722 ns data delay
```

`disp_buf_d2` is the display buffer bank select feeding the DDR address. A
setup violation here can cause reads from the wrong bank — a direct mechanism
for the observed `has_frame=0` frozen-screen signature. **This is candidate 2
(bank race) with a named register and measured violation.** w-a3 owns the
investigation; one pipeline register fixes it.

### Implication for the budget

| Decode clock | Budget cycles/MB | Margin at 558 total | Status |
| ---:| ---:| ---:| --- |
| **20 MHz (current)** | **570** | **1.02× (12 cycles)** | **CRITICAL — engineering zero** |
| 45 MHz (if fabric allows) | 1,282 | 2.30× (724 cycles) | Conditional on unknown Fmax |

**570 cycles/MB is the working budget.** The fabric Fmax is unmeasured.
**45 MHz is STRONGLY RECOMMENDED** — 20 MHz gives 12 cycles of margin which
is not a viable design point. The difference between these two numbers is the
difference between "impossible" and "comfortable."

## Verdict

**THIS IS A DESIGN TARGET. There is no decode pipeline to measure (#19).**

Budget total: **558 cycles/MB**, margin **12 cycles (1.02×)** at 20 MHz / 30 fps.
MC breaking point: **262 cycles/MB** (vs 250 allocated — 12 cycles headroom).
**At 45 MHz: margin 2.30×, MC breaking point 974 cycles.** These numbers are design
constraints for a pipeline that w-rel is building — they are not measured
throughput of an existing decoder.

**20 MHz is not a viable design point for 30 fps content.** A 5% MC overrun (13
cycles) breaks realtime. This is not survivable as a design margin.

**45 MHz converts every MANDATORY constraint to OPTIONAL.** At 1,282 cycles/MB,
all unbuilt stages could overrun by 50% and still pass with 1.69× margin.
This is the architectural conclusion.

The budget has three provenance tiers:
- **EXTRAPOLATED from measurement:** deblock (100, from w-deblock sim at `feat/deblock`)
- **ESTIMATED for unbuilt modules:** MC (250), DDR write (50), parse_full (50), dequant (48)
- **ALLOWANCE:** intra_pred (30), control (30)

**100% of the budget is for modules not instantiated in the synthesised design.**
Parse (3.2 cycles/MB measured) is the only stage in the probe, and it accounts
for 0.6% of the budget. The remaining 99.4% is design target.

**Consequence for MC:** adjacent-MB overlap exploitation is **MANDATORY**
at 20 MHz / 30 fps. Without it, MC must stay under 262 cycles/MB. With it
(~150 cycles/MB estimated), margin improves to 1.24× — still tight but viable.

**Do not report this budget as "measured throughput."** It is a feasibility
analysis based on module-level measurements and engineering estimates. The
first real throughput measurement will come when the integration datapath
exists and the full-frame sim exercises it.

## Critical path status (2026-07-27, CORRECTED ×3)

**The 39.86 ns / 25.09 MHz Fmax IS `decode_stub` — and `decode_stub` IS the
decode path (#19).** There is nothing behind it. All 10 worst `clk_sys`
intra-domain paths run through `decode_stub|lat_qp[4]` →
`decode_stub|recon_dbg[5]` (22 logic levels, routing variants only).

Previous corrections treated decode_stub as "contamination" or "dead code" in
the measurement. **It is not dead code — it is the only decode logic in the
synthesised design.** The 25.09 MHz figure IS the fabric Fmax of the current
product build. What it is NOT is the Fmax of a future production pipeline,
because that pipeline does not exist to measure.

**When the integration datapath replaces `decode_stub`:**
- The 39.86 ns path disappears (it was internal to the probe)
- A new critical path emerges from the real pipeline
- That path's delay determines whether 45 MHz is achievable
- Until then: design to 20 MHz / 570 cycles/MB (30 fps worst-case)
- Design to 570 cycles/MB (20 MHz). "Unknown limit" is not "high limit"

**The `clk_ddr` violation IS real and in the product path:**
`disp_buf_d2 → DDRAM_ADDR` at -0.213 ns, 7 logic levels. One pipeline
register fixes it. w-a3 owns this investigation.

**Error record:** This document has been corrected twice on the clock question
within two hours. At `71e509b` it said "target 60 MHz." At `747d960` it said
"fabric tops out at 25 MHz." Both were wrong — the first from an estimate that
excluded routing, the second from a fitter number that measured a diagnostic
shim. The budget (570 cycles/MB at 30 fps, previously 684 at 25 fps, 20 MHz) has
been at this clock throughout because it was never loosened on the strength of either claim.

## Ratchet audit: commit 3fda008 (2026-07-27)

**Audit requested by parent.** Commit `3fda008` widened two throughput ratchet
fixtures (320x240 and wcap) after the cabac-scoreboard + rel-mc merges added
DPB and MC fetch FSM wiring to `decode_stub.sv`.

### Changes

| Threshold | Before | After | Widening |
| --- | ---:| ---:| ---:|
| 320x240 `max_cycles_per_mb` | 282.69 | 320.0 | +13.2% |
| 320x240 `diagnostic_paint` | 270.0 | 305.0 | +13.0% |
| wcap `max_cycles_per_mb` | 280.17 | 320.0 | +14.2% |
| wcap `diagnostic_paint` | 270.0 | 305.0 | +13.0% |

Claimed measurements: total 301.48 cycles/MB, diagnostic_paint 288.26 cycles/MB.
Claimed headroom: ~6% on both thresholds.

### Findings

1. **Measurement provenance: UNVERIFIED.** The commit message claims specific
   numbers (301.48, 288.26) but no simulation log, measurement artifact, or CI
   output was committed alongside. The numbers appear only in the commit message
   and cannot be independently verified from the repository.

2. **Structural explanation: SOUND.** DPB registered outputs adding pipeline
   latency to the diagnostic paint loop is the expected direction of change.
   A ~32 cycle/MB increase (~12.5%) for DPB + MC FSM wiring is not unreasonable.

3. **Detection sensitivity: PRESERVED.** Headroom percentages are consistent
   with pre-widening values (~5.5-6%). The widened bound still catches
   regressions >6% (~19 cycles/MB). A 250 cycle/MB MC addition would blow
   past 320 decisively.

4. **624x480 fixture: INCONSISTENCY.** The primary 624x480 fixture
   (`max_cycles_per_mb: 272.36`) was **not widened**. If DPB wiring adds ~32
   cycles/MB equally across resolutions, the 624x480 fixture will fail when
   next exercised against the merged code. This needs resolution.

5. **Metric is transient.** `diagnostic_paint` exists only because the
   production pipeline is not built. Once MC and deblock replace the paint
   loop, this threshold becomes meaningless. The widening is in a proxy metric
   with a limited remaining lifespan.

### Verdict

**JUSTIFIABLE RE-BASELINE, not a rubber stamp.** The explanation is structurally
sound, the headroom percentages are consistent, and detection sensitivity is
preserved. However, the measurement should have been committed as an artifact,
and the 624x480 inconsistency needs to be resolved.

**Recommendations:**
1. Widen the 624x480 fixture to match, or verify it was intentionally left
2. Commit a reproducible sim log when re-baselining ratchets
3. Mark `diagnostic_paint` thresholds as TRANSIENT — they expire when paint
   is replaced by production stages

## Ratchet

`tools/check_decode_throughput.py` consumes the existing full-frame comparison
JSON and a `misterplex.decode_throughput_ratchet.v1` manifest. The full-frame
RTL gate now writes a separate report under `build/realtime_throughput/` for
known fixtures, copying run label, fixture source, and geometry into the JSON.
`tests/unit/test_decode_throughput_gate.sh` proves RED by lowering the cycle and
margin thresholds.

## Instrument-integrity audit (2026-07-27, per parent directive #16)

### Gate 1: Throughput ratchet (`test_decode_throughput_gate.sh`)

**Q1 — What does the pass/fail assertion literally compare?**

`check_report()` compares: `measured.cycles_total` vs `max_cycles_total`,
`cycles_per_frame` vs max, `cycles_per_mb` vs max, `budget.margin_ratio` vs
min, `effective_fps` vs min, and per-stage `cycles_per_mb` vs stage thresholds.
Structural gate: if any production stage is `not_implemented`, emit INCOMPLETE.

**Q2 — What does it NOT cover?**

1. **The gate does NOT run a simulation.** It feeds synthetic JSON with hardcoded
   cycle counts to `check_decode_throughput.py`. A reader seeing "PASS decode
   throughput gate" might assume a sim ran. It did not — that is
   `test_stream_path_full_frame_compare.sh`, a separate gate.
2. **`effective_fps` is 98.7% diagnostic paint.** The 65.9 fps headline measures
   the pixel-painting rate of `decode_stub`, not the decoder. The real decode
   cost is 3.2 cycles/MB; the rest is painting diagnostics at 1 px/cycle.
3. **Only 624x480 fixture is exercised.** 320x240 and wcap fixtures are not
   tested by this gate (they would be tested by the full-frame sim gate).

**Q3 — Can it fail?** YES. Red-proven in three dimensions: tightened thresholds
→ rc≠0; INCOMPLETE with unimplemented stages; OK when all measured. Specific
failure messages verified by grep.

### Gate 2: Visual verdict classifier (`test_hw_visual_compare.py`)

**Q1 — What does the pass/fail assertion literally compare?**

Synthetic images → `hw_visual_compare.py` → verdict ID. Five branches tested:
EXACT_MATCH (dispersion ratio=1.0), NO_FRAME_DELIVERED (ratio<1.02),
COLOUR_PATH_DEFECT (BT.601/709 ratio>30.0, U/V swap ratio>5.0),
GEOMETRY_CONTENT_DEFECT (dx=5 detected), INDETERMINATE (rc=2). Plus delivery
short-circuit paths for `frame_status=absent` and non-YUV colorspace.

**Q2 — What does it NOT cover?**

1. **Synthetic images only, no device validation.** By design — STA is not
   closed. But a reader might assume device-validated.
2. **No gradual degradation.** All inputs are clear cases. A 95%-correct image
   with 5% chroma error in one region has not been tested.
3. **No chroma-DC-specific defect test.** Given instrument failure #16 (chroma
   DC Hadamard missing from RTL), a chroma-only error (correct luma, wrong
   chroma reconstruction) would produce subtle colour shifts. The U/V swap test
   is the closest proxy but less subtle than a real chroma DC defect.

**Q3 — Can it fail?** YES. Every classification branch red-proven with synthetic
input. Re-verified on this host after migration.

### Gaps stated in headline

- Throughput gate tests checker logic, not sim. `effective_fps` is paint rate.
- Visual gate is synthetic-only, not device-validated. No chroma-DC test.
