# DPB fetch-path bandwidth budget

**Owner:** w-dpb  
**Branch:** `feat/dpb-fetch`  
**Date:** 2026-07-27  
**Status:** BUDGET DRAFT — no RTL committed against this yet

This document is the single source of truth for the decoded picture buffer
fetch and writeback cycle budget. Every number is labelled MEASURED, ESTIMATED,
or ALLOWANCE. No number may be used without its label.

---

## 1. Clock and timing contract

| Parameter | Value | Label | Source |
|-----------|------:|-------|--------|
| Decode clock (`clk_sys`) | 20.000 MHz | **MEASURED** | `pll_0002.v` `output_clock_frequency0("20.000000 MHz")`; `Plex.sv:215` `.outclk_0(clk_sys)` |
| SDRAM clock (`clk_sdram`) | 100–142 MHz selectable | **MEASURED** | `pll_0002.v` `output_clock_frequency1` ifdef chain; default 100 MHz |
| DDRAM clock | 90 MHz | **MEASURED** | `pll_0002.v` `output_clock_frequency2("90.000000 MHz")` |
| Target frame rate | **30 fps** | **MEASURED** | w-osd: PMS STREAM path delivers 30 fps (w-arch v6) |
| STREAM path geometry | 640×480 = 40×30 = 1200 MB/frame | **MEASURED** | w-osd: PMS transcodes to 640×480 coded on STREAM path |
| MBs per second | 36,000 | **MEASURED** | 1200 × 30 |
| Cycles per frame (20 MHz) | 666,667 | **MEASURED** | 20 MHz / 30 fps |
| Cycles per MB (20 MHz) | **555.6** | **MEASURED** | 666,667 / 1200 — **DOES NOT FIT** (w-arch v6) |
| Cycles per frame (45 MHz) | 1,500,000 | **TARGET** | 45 MHz / 30 fps |
| Cycles per MB (45 MHz) | **1,250** | **TARGET** | 1,500,000 / 1200 — 2.24× over allocation |

**CRITICAL CORRECTION (w-arch v6, 2026-07-27):** 20 MHz at 30 fps / 1200 MBs gives
only 556 cycles/MB. The fleet allocation alone is 558 cycles — **it exceeds the
budget by 2 cycles before DPB fetch is even counted.** 20 MHz is arithmetically
impossible. 45 MHz (VCO=360/8, 1:2 ratio to 90 MHz DDR) is REQUIRED, giving
1,250 cycles/MB (2.24× margin).

**Previous 25 fps / 624-width numbers are OBSOLETE.** Retained below as
~~strikethrough~~ for audit trail but must not be used for planning.

~~| Target frame rate | 25 fps | — | PMS 480p stream target (rawvideo path only) |~~
~~| Coded geometry | 624×480 = 39×30 = 1170 MB/frame | — | rawvideo path forced via ffmpeg scale |~~
~~| Cycles per MB (20 MHz, 25 fps) | 683.76 | — | 800,000 / 1170 — OBSOLETE |~~

**Clock-dependent note:** every cycle count in this document scales linearly
with `clk_sys`. The actual decode-fabric Fmax has **never been measured** —
no Quartus fit with real decode modules has ever run. The previously cited
"25.09 MHz" figure (critical path 39.86 ns) was measuring `decode_stub`, a
diagnostic shim, not the decoder (w-arch v5, 2026-07-27). The real limit is
**UNKNOWN**, which is not the same as "high."
**All budgets in this document now use 45 MHz as the planning assumption.**
20 MHz does not close. 45 MHz feasibility is conditional on the first fit
with real decode modules — which per #19 has never happened.

## 2. Existing stage allocation (from fleet measurements)

| Stage | Cycles/MB | Label | Source |
|-------|----------:|-------|--------|
| MC interpolation | 250 | **ALLOWANCE** | Fleet allocation (w-mc) |
| Deblock filter | 150 | **ALLOWANCE** | Fleet allocation (w-deblock) |
| CAVLC parse | 50 | **ALLOWANCE** | Fleet allocation |
| DDR write (bitstream) | 50 | **ALLOWANCE** | Fleet allocation |
| Dequant + IDCT | 48 | **ALLOWANCE** | Fleet allocation |
| Intra prediction | 30 | **ALLOWANCE** | Fleet allocation |
| Control | 30 | **ALLOWANCE** | Fleet allocation |
| **Subtotal** | **608** | | |
| **Total budget (45 MHz)** | **1,250** | | 45 MHz / 30 fps / 1200 MBs |
| **Remaining margin** | **642** | | 1,250 − 608 = 642 cycles (2.06× headroom) |

**At 45 MHz the DPB fetch has a COMFORTABLE allocation.** The 289-cycle
64-bit burst fetch fits within the 642-cycle margin without pipelining.
Even serial execution (608 + 289 = 897) closes with 1.39× margin at 45 MHz.

~~**Total budget (20 MHz)** | **556** | **DOES NOT FIT** | 558 > 556~~

**Critical observation:** the DPB fetch path has **no explicit allocation** in
this table. It was not counted in the 608-cycle sum. The 250-cycle MC
allocation covers interpolation arithmetic only — not the memory transactions
to obtain the reference window.

## 3. DPB traffic per macroblock

### 3a. Reference fetch (read from DDR, deblocked reference picture)

| Component | Bytes/MB | Label | Source |
|-----------|----------:|-------|--------|
| Luma 21×21 window | 441 | **MEASURED** | 6-tap half-pel filter needs (16+5)=21 rows/cols; `h264_dpb_one_ref` issues 441 reads |
| Chroma U 9×9 window | 81 | **MEASURED** | Bilinear chroma needs (8+1)=9; `h264_dpb_one_ref` issues 81 reads |
| Chroma V 9×9 window | 81 | **MEASURED** | Same as U plane |
| **Total read** | **603** | | |

### 3b. Filtered writeback (write current picture after deblock)

| Component | Bytes/MB | Label | Source |
|-----------|----------:|-------|--------|
| Luma 16×16 | 256 | **MEASURED** | `h264_deblock_writeback_ctrl` commits 256 Y samples per MB |
| Chroma U 8×8 | 64 | **MEASURED** | 64 U samples per MB |
| Chroma V 8×8 | 64 | **MEASURED** | 64 V samples per MB |
| **Total write** | **384** | | |

### 3c. Total DPB traffic

| Metric | Value | Label |
|--------|------:|-------|
| Total bytes/MB | 987 | **MEASURED** |
| Total bytes/frame | 1,154,790 | **MEASURED** (987 × 1170) |
| Throughput at 25 fps | 28.87 MB/s | **MEASURED** |

## 4. Byte-serial access: why it does not work

At one byte per `clk_sys` cycle, reading 603 bytes and writing 384 bytes
costs **987 cycles/MB** — exceeding the entire 684-cycle decode budget by
**1.44×**. The DPB alone would consume more time than the decoder has for all
stages combined.

**Label: MEASURED.** The byte-serial `h264_dpb_one_ref` module in current RTL
issues exactly one `mem_rd` per cycle and one response per cycle, producing
this 987-cycle cost directly.

## 5. 64-bit coalesced access

The f2sdram bridge to HPS DDR3 provides a 64-bit (8-byte) data path at up
to 90 MHz (DDRAM_CLK). Each "beat" transfers 8 bytes.

### 5a. Read beats (reference fetch)

Reference windows are **unaligned** — the motion vector places the origin at
an arbitrary byte offset. Row-by-row access:

| Component | Bytes/row | Rows | Beats/row (aligned) | Beats/row (worst unaligned) | Total aligned | Total worst |
|-----------|----------:|-----:|--------------------:|----------------------------:|--------------:|------------:|
| Luma | 21 | 21 | 3 | 4 | 63 | 84 |
| Chroma U | 9 | 9 | 2 | 2 | 18 | 18 |
| Chroma V | 9 | 9 | 2 | 2 | 18 | 18 |
| **Read total** | | | | | **99** | **120** |

### 5b. Write beats (filtered writeback)

Writeback addresses are **macroblock-aligned** (mb_x, mb_y are integer grid
positions), so luma rows start at `base + mb_y*16*624 + mb_x*16`. Because
`624 mod 8 = 0` and `mb_x*16 mod 8 = 0`, luma write rows are always 8-byte
aligned. Chroma rows start at `base + U_offset + mb_y*8*312 + mb_x*8`;
`312 mod 8 = 0` and `mb_x*8 mod 8 = 0`, also always aligned.

| Component | Bytes/row | Rows | Beats/row | Total |
|-----------|----------:|-----:|----------:|------:|
| Luma | 16 | 16 | 2 | 32 |
| Chroma U | 8 | 8 | 1 | 8 |
| Chroma V | 8 | 8 | 1 | 8 |
| **Write total** | | | | **48** |

### 5c. Total 64-bit coalesced beats

| Scenario | Read | Write | Total beats | Label |
|----------|-----:|------:|------------:|-------|
| Aligned | 99 | 48 | **147** | **ESTIMATED** (assumes 8-byte-aligned row starts for reads) |
| Worst-case unaligned reads | 120 | 48 | **168** | **ESTIMATED** (all luma read rows cross an 8-byte boundary) |

## 6. Burst-mode access

DDR supports burst transfers. Each burst has a command-issue overhead (CAS
latency + bridge arbitration), then data arrives at one beat per cycle on the
DDR interface. The f2sdram bridge through `ddr_bus_arbiter` adds contention
with the bitstream reader (m1) and presentation frame reader (m0).

Per-row bursts with **2-cycle command overhead** (ESTIMATED — actual bridge
latency not yet measured):

| Component | Bursts | Data beats | Overhead | Total cycles | Label |
|-----------|-------:|-----------:|---------:|-------------:|-------|
| Luma read | 21 | 63 | 42 | 105 | **ESTIMATED** |
| Chroma U read | 9 | 18 | 18 | 36 | **ESTIMATED** |
| Chroma V read | 9 | 18 | 18 | 36 | **ESTIMATED** |
| Luma write | 16 | 32 | 32 | 64 | **ESTIMATED** |
| Chroma U write | 8 | 8 | 16 | 24 | **ESTIMATED** |
| Chroma V write | 8 | 8 | 16 | 24 | **ESTIMATED** |
| **Total** | **71** | **147** | **142** | **289** | **ESTIMATED** |

**Critical correction to existing docs:** the file `docs/p3-mc-dpb-bandwidth.md`
states a "100 MHz / 3418 cycles per macroblock" figure. That uses the **SDRAM**
clock, not the decode clock. The decode clock is `clk_sys` at 20 MHz, giving
684 cycles/MB. The SDRAM clock is irrelevant for the decode pipeline budget.
The existing document has been superceded by this one.

## 7. Adjacency overlap measurement — from real content

**Source:** `tests/fixtures/p3_inter_pred/pframe1_mb_v1.json` — a P-frame
from the 320×240 Baseline x264 fixture generated with `partitions=none`,
`ref=1`, `bframes=0`. This is 20×15 = 300 macroblocks.

| Metric | Value | Label |
|--------|------:|-------|
| MBs with non-empty parts | 279 / 300 | **MEASURED** |
| Zero-MV macroblocks | 134 / 279 = 48.0% | **MEASURED** |
| H-adjacent pairs with overlap | 247 / 248 = 99.6% | **MEASURED** |
| Average overlap area | 103.1 / 441 bytes = 23.4% | **MEASURED** |
| Median overlap area | 105 / 441 bytes = 23.8% | **MEASURED** |
| Zero-overlap pairs | 1 / 248 = 0.4% | **MEASURED** |
| Same-MV adjacent pairs | 160 / 248 = 64.5% | **MEASURED** |
| Median MV diff (h-adjacent) | 0 qpel both axes | **MEASURED** |
| Mean MV diff x (h-adjacent) | 2.1 qpel | **MEASURED** |
| Mean MV diff y (h-adjacent) | 2.2 qpel | **MEASURED** |
| Max MV diff x (h-adjacent) | 59 qpel (~15 px) | **MEASURED** |
| Max MV diff y (h-adjacent) | 20 qpel (5 px) | **MEASURED** |

### Cache savings with prev-MB row reuse

When MVs match between adjacent MBs, the 21×21 windows overlap by exactly 5
columns × 21 rows = 105 bytes. A simple SRAM buffer holding the previous MB's
21×21 luma window allows avoiding those 105 byte-reads.

| Metric | Value | Label |
|--------|------:|-------|
| Naive total luma fetch | 123,039 bytes/frame (279 × 441) | **MEASURED** |
| Saved by prev-MB overlap | 25,558 bytes = 20.8% | **MEASURED** |
| Net fetch per MB (avg) | 349.4 bytes | **MEASURED** |
| Saved read beats (64-bit) | ~13 of 63 aligned | **ESTIMATED** |

**Measurement limitation:** this is one P-frame from one 320×240 fixture. The
624×480 production content may have different MV distributions. The overlap
measurement has not been repeated on 624×480 content because ffprobe's MV side
data export does not produce structured per-MB vectors for raw annexb. This
is a **known gap** — the 320×240 result is directionally correct but not
confirmed at target resolution.

**Verdict on adjacency overlap: HELPFUL BUT NOT TRANSFORMATIVE.** A 20%
savings on luma reads reduces the 63-beat luma read cost to ~50 beats,
saving ~13 cycles. This does not change the fundamental budget picture.

## 8. Does the DPB fit in the budget?

### The sequential model (one thing at a time)

| Item | Cycles/MB | Source |
|------|----------:|--------|
| Existing stages | 608 | Allocation table (§2) |
| DPB fetch+write (burst) | 289 | Estimated (§6) |
| **Total** | **897** | |
| Budget | 684 | |
| **Deficit** | **−213** | **DOES NOT FIT (1.31×)** |

Even with adjacency overlap savings (~13 cycles), the deficit is −200.

### The pipelined model (overlap DPB with MC)

MC interpolation (250 cycles) cannot start until the reference window is
fetched. But DPB writeback (filtered samples into current picture) can happen
while the *next* MB's parse + IDCT runs. The deblock filter outputs filtered
samples for MB[n] while parse has moved to MB[n+1] or beyond.

**Pipelined read path:** the critical serial chain is:
1. Fetch reference window for MB[n] → 177 cycles read (burst, §6)
2. MC interpolation on fetched data → 250 cycles
3. Total serial: 427 cycles for fetch+MC

Other stages (parse, IDCT, deblock writeback) can overlap with this if
the DDR port is shared properly.

**Pipelined write path:** deblock writeback (112 cycles burst estimate)
runs one or more MBs behind the current fetch, on the same DDR port via
time-division multiplexing.

### Pipelined budget

| Slot | Cycles | Notes |
|------|-------:|-------|
| Reference fetch (DDR read) | 177 | 21+9+9 row bursts for luma+chroma |
| MC interpolation | 250 | Overlaps with nothing — needs the fetched window |
| Serial fetch+MC | **427** | |
| Parse + IDCT + intra (overlap) | 158 | Can run while DDR reads are in flight IF on a separate port |
| Deblock writeback (overlap) | 112 | Runs for MB[n−1] while MB[n] fetches |
| Control | 30 | Interleaved |
| **Dominant serial path** | **427** | fetch + MC |
| Budget | 684 | |
| **Margin** | **257** | **FITS (1.60× headroom)** |

**BUT:** this pipelined model assumes the DDR port is not contended during
the 177-cycle fetch window. The current `ddr_bus_arbiter` has only two
masters: m0 (presentation frame read) and m1 (bitstream ring read). Adding
DPB fetch as m2 requires either:

1. A **3-master arbiter** on the existing f2sdram port, or
2. A **second f2sdram port** (w-cap investigation)

If the DDR port is shared, the 177-cycle fetch estimate grows by arbitration
stalls. At worst, if presentation holds the port for a full scan line (156
qwords = 156 cycles at 20 MHz), the DPB fetch could stall for that long,
breaking the pipeline.

## 9. DDR port contention analysis

Current DDR traffic on the single f2sdram port:

| Master | Traffic | Rate | Label |
|--------|---------|-----:|-------|
| m0: Presentation frame read | 624×480×2 bytes × 60 Hz (RGB565) | 35.9 MB/s | **MEASURED** |
| m1: Bitstream ring read | ~70 KB per 12 frames × (25/12) | 0.15 MB/s | **MEASURED** |
| DPB reference fetch | 603 B/MB × 1170 × 25 | 17.6 MB/s | **MEASURED** |
| DPB filtered writeback | 384 B/MB × 1170 × 25 | 11.2 MB/s | **MEASURED** |
| **Total** | | **64.9 MB/s** | |

The DDR3 through f2sdram at 90 MHz, 64-bit, can sustain a theoretical peak of
720 MB/s. After DRAM refresh, CAS latency, and bus turnaround overhead, a
realistic sustained throughput is ~400–500 MB/s. The 64.9 MB/s total is
**~15% of available bandwidth** — plenty of raw bandwidth.

The problem is **latency, not throughput.** Presentation reads are bursty
(one full scan line = 156 beats every ~26 µs for 60 Hz). If a presentation
burst occupies the port for 156 beats, a DPB fetch that arrives during that
burst stalls for up to 156 cycles. At 20 MHz decode clock, that is 156 cycles
of decode time wasted — eating into the 257-cycle pipelined margin.

### Second f2sdram port (w-cap dependency)

The Cyclone V HPS supports up to 6 f2sdram ports. w-cap has established that
a second port **IS achievable** but at a real cost: all 4 SDRAM data channels
are currently used, and freeing a pair requires downgrading the 128-bit video
scaler buffer to 64-bit (dropping scaler bandwidth from 1.6 GB/s to 800 MB/s,
still above the ~497 MB/s that 1080p60 requires). This also invalidates the
bit-identity baseline used for two-slot fit verification. Full analysis in
`build/sta_paths/f2sdram_port_analysis.md`. **Coordinate with w-cap before
assuming this port is available.**

**With a dedicated port:** fetch takes 177 cycles, MC takes 250, total 427
of 684 = **1.60× margin**. Writeback overlaps on the decode port or shares
the DPB port.

**Without a dedicated port:** fetch takes 177 + up to 156 stall = 333 cycles
worst case, plus MC 250, total 583 of 684 = **1.17× margin**. This is tight
but may close if presentation bursts are short enough on average.

**Additional risk:** `clk_ddr` already sits at -0.21 ns intra-domain slack
at 90 MHz. A wider bus arbiter adding DPB as a third master in the DDR domain
will likely worsen this. The next fit may trade a cross-domain timing failure
for an intra-domain one.

## 10. SRAM requirements for the DPB fetch path

| Resource | Size | Purpose |
|----------|-----:|---------|
| Luma window buffer | 441 bytes (21×21) | Holds fetched luma reference window for MC |
| Chroma U window buffer | 81 bytes (9×9) | Holds fetched chroma U reference window |
| Chroma V window buffer | 81 bytes (9×9) | Holds fetched chroma V reference window |
| Previous-MB luma cache | 441 bytes | Adjacency overlap reuse (optional, saves ~20% reads) |
| **Total** | **1,044 bytes** | Fits in Cyclone V M10K block RAM |

No external SRAM needed. The reference pictures themselves live in DDR3
(449,280 bytes per frame × 2 banks = 898,560 bytes).

## 11. Correctness constraints

1. **Deblock-before-publish:** the DPB must never serve unfiltered reference
   samples. `h264_deblock_writeback_ctrl` commits filtered samples into the
   current picture bank. The current→reference bank swap happens only at
   `frame_done` after all MBs are deblocked. The `ref_ready` signal gates
   fetch — no fetch may issue while `ref_ready=0`.

2. **IDR invalidation:** `idr_start` clears `ref_ready`. The first P-frame
   after IDR must not attempt reference fetch until the IDR frame is fully
   decoded and deblocked.

3. **Edge clamping:** motion vectors may point outside [0, width)×[0, height).
   The DPB clamps coordinates to picture boundaries (replicate edge pixels).
   This is normative per H.264 §8.4.2.2.1 and tested in
   `test_p3_dpb_mc_rtl_sim.sh` clamp red-check.

4. **Bank addressing:** two I420 frame banks at `BANK0_BASE=0` and
   `BANK1_BASE=0x80000` (DDR_FRAME_YUV420P_BANK_STRIDE). Plane offsets
   Y=0, U=299520, V=374400. Strides Y=624, U/V=312. All from
   `ddr_frame_layout_params.svh`.

## 12. Interface contract (agreed with w-mc)

The DPB fetch interface as implemented in `h264_dpb_one_ref`:

**Request (from MC to DPB):**
- `fetch_start` — pulse to begin
- `fetch_mb_x, fetch_mb_y` — macroblock grid position
- `fetch_part_mode` — partition mode (0=16×16, 1=16×8, 2=8×16, 3=8×8, 4=sub)
- `fetch_part_idx` — partition index within MB
- `fetch_part_w, fetch_part_h` — partition size in pixels
- `fetch_mv_x_qpel, fetch_mv_y_qpel` — signed motion vector in quarter-pel

**Response (from DPB to MC):**
- `fetch_busy` / `fetch_done` — handshake
- `fetch_error_no_ref` — error if reference not ready
- `luma_frac_x/y` — quarter-pel fractional position (2-bit)
- `chroma_frac_x/y` — eighth-pel fractional position (3-bit)
- `luma_window_valid/idx/sample` — streaming luma window data (441 beats)
- `chroma_{u,v}_window_valid` / `chroma_window_idx/sample` — streaming chroma (81 beats each)

**The DPB derives and clamps all addresses.** The requester never computes
source coordinates. The DPB returns raw bordered windows; the requester owns
interpolation and arithmetic.

## 13. Scaling table — CONSTRAINED by CDC relationships

**2026-07-27 v6 correction from w-arch:** 20 MHz is **arithmetically
impossible** at 30 fps / 1200 MBs (only 556 cycles/MB; allocation needs 558).
45 MHz is REQUIRED, not optional.

The cross-domain relationships constrain which frequencies are safe:
- **40 MHz** vs clk_ddr(90 MHz): 4:9 ratio, 2.778 ns worst-case setup — WORSE
  than the relationship that already failed at -2.137 ns. **RULED OUT.**
- **45 MHz** vs clk_ddr(90 MHz): 1:2 exact ratio, 11.111 ns — the only
  safe candidate. VCO=360 MHz / 8 = 45 MHz. **REQUIRED.**
- **60 MHz** vs clk_ddr(90 MHz): 2:3 ratio, 5.556 ns — the SAME zone that
  produced the -2.137 ns failure. **RULED OUT.**

| clk_sys | Cycles/MB | DPB serial (608+289) | Margin | Verdict |
|--------:|----------:|---------------------:|-------:|---------|
| 20 MHz | 556 | 897 | **−341** | **IMPOSSIBLE** — allocation alone exceeds budget |
| 45 MHz | 1,250 | 897 | 353 (1.39×) | **OK** — comfortable even without pipelining |
| 45 MHz pipelined | 1,250 | 647 | 603 (1.93×) | **WIDE** — fetch overlaps MC |

**Note:** 45 MHz feasibility is UNKNOWN — conditional on the first fit with
real decode modules (per #19, no such fit has ever existed). The real
decode-fabric Fmax has never been measured.

## 14. Verdict and next steps

**PIPELINED FEASIBILITY: COMFORTABLE at 45 MHz. 20 MHz is DEAD.**

At 45 MHz / 1,250 cycles/MB:
- Serial (all stages + DPB fetch): 897/1,250 = 1.39× margin ✓
- Pipelined (fetch overlaps MC): 647/1,250 = 1.93× margin ✓
- DDR port contention at 45 MHz is less critical — 353 spare cycles absorb it

At 20 MHz / 556 cycles/MB:
- Allocation alone (558) > budget (556). Nothing fits. No DPB design saves this.

**The DPB fetch path is no longer the bottleneck.** The clock is.

**2026-07-27 second f2sdram port correction:** w-cap has established a second
port IS achievable, but at a real cost: all 4 data channels are currently
used, and freeing a pair requires downgrading the 128-bit video scaler buffer
to 64-bit (dropping scaler bandwidth from 1.6 GB/s to 800 MB/s — still above
the ~497 MB/s that 1080p60 needs). This also invalidates the bit-identity
baseline used for two-slot fit verification. Full analysis in
`build/sta_paths/f2sdram_port_analysis.md`.

**Also noted:** `clk_ddr` already sits at -0.21 ns intra-domain slack at
90 MHz. Any additional logic in that domain (e.g. a wider bus arbiter) will
likely worsen this. The next fit may trade a cross-domain failure for an
intra-domain one.

**Dependencies:**
1. **w-cap (second f2sdram port):** achievable but has scaler bandwidth cost.
   Coordinate before assuming it. Without it, DPB fetch contends with
   presentation on the same port. At 45 MHz the margin is comfortable enough
   that moderate contention (~100 cycles) is absorbable.
2. **w-arch (clock study):** 45 MHz is now REQUIRED (w-arch v6). Decode-fabric
   Fmax is UNKNOWN — no fit with real decode modules has run (per #19,
   `decode_stub` IS the decode path, and it is a probe). The first real fit
   establishes whether 45 MHz is achievable.
3. **w-deblock:** deblock writeback timing determines when filtered samples
   are available for the current picture bank. The DPB must not read from
   the current bank until writeback is complete.
4. **w-mc:** MC interpolation starts after fetch_done. The 250-cycle MC
   allocation is the dominant cost after fetch completes.

**The honest framing (REVISED):** at 45 MHz the DPB fetch path is
COMFORTABLE — serial execution (608 + 289 = 897) fits within 1,250 with
1.39× margin. Pipelined (fetch overlaps MC: max(250, 289) + 358 = 647) gives
1.93× margin. The question is no longer "does it fit?" but "can the fabric
reach 45 MHz?" — which is unknown and conditional on the first real fit.

~~**Previous framing (20 MHz, OBSOLETE):** the DPB fetch path was MARGINAL.~~

## 15. Width-640 budget impact (2026-07-27, w-osd/w-arch coordination)

w-osd established that the STREAM path (the one needed for FPGA-native decode)
produces coded 640×480 = 40×30 = **1200 MBs/frame** at **30 fps** (not 25).
w-arch v6 confirmed 20 MHz is arithmetically impossible at these parameters.

| Parameter | Value | Notes |
|-----------|------:|-------|
| MBs/frame | 1200 | 40×30 |
| Frame rate | 30 fps | STREAM path measured |
| MBs/s | 36,000 | |
| Cycles/MB (20 MHz) | 556 | **DOES NOT FIT** — allocation alone is 558 |
| Cycles/MB (45 MHz) | 1,250 | 2.24× over 558 allocation |
| DDR frame bytes | 460,800 | < bank stride 0x80000 (524,288) ✓ |
| Luma read/MB | 441 B | Unchanged — geometry-independent |
| DPB serial budget (45 MHz) | 897/1,250 | 1.39× margin |
| DPB pipelined budget (45 MHz) | 647/1,250 | 1.93× margin |

**Verdict:** the budget **closes comfortably at 45 MHz.** At 20 MHz nothing
fits regardless of DPB design. The per-MB costs are geometry-independent;
only the MBs/frame count changed. The DPB fetch path is no longer the
marginal constraint — the clock is.

**RTL verification at 640:** the DPB parameterisation has been **measured** at
FRAME_W=640 (not merely read). The width-edge test exercises MB column 39 with
a positive MV crossing the right boundary:
- 441/441 luma samples from column 39 ✓
- 126/441 samples hit the right-edge clamp ✓
- 81/81 chroma samples from column 39 ✓
- Zero errors in luma or chroma

**Next steps for this worker:**
1. ~~Commit this budget document.~~ DONE.
2. Build a DPB fetch controller that replaces the byte-serial `h264_dpb_one_ref`
   with a 64-bit burst DDR interface.
3. Add a DDR read port to the fetch path (m2 on the arbiter, or second f2sdram).
   **Coordinate with w-cap on the scaler bandwidth tradeoff before proceeding.**
4. Measure actual burst latency on the f2sdram bridge (Verilator model).
5. Implement the previous-MB luma cache for adjacency overlap savings.

**Note (post #19):** steps 2–5 are building for a decode datapath that does not
yet exist. The work is still correct — the datapath will need this interface —
but "done" cannot be reached until the integration pipeline is wired. This
budget is now labelled a **DESIGN TARGET**, not a description of a working system.

---

**Provenance:** all MEASURED values have file:line citations in the table.
ESTIMATED values use the measured byte counts with assumed DDR burst
parameters. ALLOWANCE values are fleet-negotiated cycle budgets from the
parent orchestrator. No number in this document is unsourced.
