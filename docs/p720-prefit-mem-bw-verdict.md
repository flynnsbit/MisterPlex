# Pre-fit memory + bandwidth verdict (w-mem) — integration fit

**Date context:** exclusive Quartus slot with w-nostub; geometry freeze verified by parent  
(`test_720p_geometry_lane_agree` rc=0): src **960×540** / stride 960 / **777600 B**,  
Option-C `0x30180000`/`0x180000`, glass **1280×720**, 4/3 scale, **2-tap** V, PPC=2,  
`clk_pix` **29.7 MHz** (`PRESENT_CLK_PIX_PLL`, w-clock `79e0f924`).

**Verdict: YES — bandwidth closes on arithmetic. Do not hold the fit for DDR BW.**  
M10K: **agree with w-scaler that the gate is wiring**, not block count, **if** the
nostub `decode_stub` reclaim is in the same tree; scaler linebufs are a small
delta either way. **Post-fit physical M10K is still the only truth.**

---

## 1. Bandwidth (quoted arithmetic)

Theoretical f2sdram peak (upper bound, not measured efficiency):

```
clk_ddr 90 MHz × 8 B/beat = 720 MB/s   (fabric_ddr_bandwidth.hpp)
```

### Product path traffic @24 Hz (frozen geometry)

| Flow | Bytes/frame | MB/s @24 | Notes |
|------|------------:|---------:|-------|
| ARM host → bank (tight 960×540 I420) | 777,600 | **18.662** | HPS port; structural `/dev/mem` ~88 MiB/s class |
| Fabric **read native** (scale source) | 777,600 | **18.662** | m0/content reader; must use stride **960** |
| Fabric emit 1280×720 on `clk_pix` | — | **0 DDR** if direct scaler→ascal/HDMI via BRAM linebufs | preferred |
| Optional canvas writeback 1280×720 I420 | 1,382,400 | 33.178 | only if scaler dumps full canvas to DDR |
| Optional canvas scanout read | 1,382,400 | 33.178 | only if present reads canvas bank |

**Model A — direct (preferred product):**  
`host_wr + fabric_rd_native = 37.325 MB/s` → **5.18% of 720 peak**

**Model B — writeback worst case:**  
`37.325 + 66.355 = 103.680 MB/s` → **14.40% of 720 peak**

Both under a 25% theoretical-peak soft cap (`fabricProductPathFitsTheoreticalPeak`).

### Arbiter3 clients (when `FABRIC_DDR_WRITER` on)

Quoted `ddr_bus_arbiter3.sv` priority:

1. **m0** frame-store present READ (must not starve)  
2. **m2** fabric writer WE  
3. **m1** bitstream ring RD (tiny @ ~2.6 Mbit ≈ 0.32 MB/s)

Product integration fit: `FABRIC_DDR_WRITER` is **default OFF** in `Plex.qsf`
(commented). Shipping present path is **ARM bank fill + fabric read/scale**, not
fabric pixel writer. m1 ring is endgame/default-OFF. So steady-state fabric
masters are essentially **m0-class present read** (+ HPS write on the shared
controller).

Half-share lower bound if m0 always wants: **360 MB/s** available to writer class.  
Canvas scanout alone needs **33.2 MB/s @24** — **closes by >10×** on peak math.

Bitstream AU worst-case (60915 B) is not on the critical present path for this fit.

### `clk_pix` / PPC (not a DDR issue)

- CEA 720p24 totals: 1650×750×24 = **29.7 MHz** (w-clock PLL outclk_3).  
- Active pixels: 1280×720×24 = **22.12 Mpix/s**.  
- PPC=2 @ 29.7 MHz → **59.4 Mpix/s** capacity ≫ active.  
- Ship `clk_sys` 20 MHz alone **cannot** clock CEA totals (parent/sys_top:
  ascal decouples core raster from HDMI wire — 29.7 is correct for the core
  path parent verified).

**DDR BW does not reject this fit.** Remaining risk is **arbiter latency /
efficiency / sticky-m2** under real contention — unknown until parent measures
post-fit. Arithmetic headroom is large enough that a miss would be a **bug or
starvation policy**, not “not enough peak bytes.”

---

## 2. M10K — agree “wiring not blocks,” with caveats

### Measured baseline (wire6 product fit — quoted)

| | |
|--|--|
| Device | 553 M10K blocks × 10240 bits |
| Used | **465 / 553 (84%)** |
| Free blocks | **88** |
| Bit free % | ~47% — **misleading; retired for packing** (`docs/m10k-physical-blocks-wire6.md`) |

### w-scaler “~356 free”

Arithmetic identity (not a new fit report):

```
88 free (wire6) + ~268 decode_stub reclaim (parent/w-nostub brief) ≈ 356
```

**Agree:** if nostub’s stub reclaim is in **this** integration tree, free blocks
jump into the mid-hundreds and a 4/3 + 2-tap linebuf set is not the binding
constraint. **Gate is wiring / CDC / geometry agreement.**

**Caveats (do not overclaim):**

1. **356 is sum-of-briefs**, not a quoted `Plex.fit.rpt` line for the integration
   RBF. Post-fit block count can differ.  
2. **Without** stub reclaim, free stays **88**. Scaler still fits on **lower-bound
   bits** (below), but **shallow packing can burn whole blocks** — wire6
   `ddr_frame_store` line_buf already shows bad efficiency (96 blocks / 160k bits
   class in fit-budget doc). Prefer **deep/wide consolidated** RAMs (`ramstyle=M10K`,
   full line depth).  
3. Full on-chip RFS/DPB frames are **not** in this fit and must stay off M10K
   (≥90 blocks for one 720p I420 alone > 88 free).

### Line-buffer lower bound (2-tap vertical @ 960 source)

| Store | Bytes | Bits | ceil(bits/10240) LB blocks |
|-------|------:|-----:|---------------------------:|
| Luma line ×2 | 2×960 | 15,360 | **2** |
| Chroma U line ×2 | 2×480 | 7,680 | **1** |
| Chroma V line ×2 | 2×480 | 7,680 | **1** |
| Optional out line 1280 | 1280 | 10,240 | **1** |
| **LB total** | | | **~5–12** |

Even ×2–3 for dual-bank/PPC padding stays **≪ 88** and **≪ 356**.  
**1280 B luma = exactly 1 M10K bit budget** (`fabric_luma_linebuf.sv` comment).

---

## 3. HARD_FAIL fallback order (pre-thought — do **not** pre-empt)

Geometry freeze stays; only open these if **post-fit evidence** forces it.

| Priority | If fail mode | Drop / change first | Why |
|---------:|--------------|---------------------|-----|
| 1 | **M10K overflow** | 2-tap V → **1-tap / nearest** vertical (keep H filter if cheap) | Halves V line storage |
| 2 | M10K still high | **Narrow linebufs to content 960**, never 1280, on the **source** side | Frozen src is 960; 1280 only on output taps |
| 3 | M10K / routing | Collapse multiple shallow RAMs into **one deep M10K** per plane | Blocks, not bits, bind |
| 4 | **Timing `clk_pix`** | Keep 29.7; reduce **PPC 2→1** on the core path if multi-pixel path is critical | Trades mult/routing; glass rate still OK at 24 with 29.7 |
| 5 | Timing `clk_sys`/`clk_ddr` | Do **not** bump clk_sys for CEA; isolate failing path (ascal vs frame_store) | Parent: core ≠ HDMI wire |
| 6 | **ALM** | Disable default-OFF decode/fabric-writer leaves if accidentally elaborated | Product path does not need them |
| 7 | Last resort | Fall glass to **960×540 1:1** (no upscale) behind a named flag | Loses “720p output”; last resort only |

**Do not** open: true 720p source banks, fabric H.264 decode, dual-SDRAM, or
weakening the `.svh`/`.hpp` lockstep test.

---

## 4. Barrier / visibility review (frame publish path) — DONE

**Question:** does the product path have rd-duck’s `atomic_signal_fence`-as-DMB bug?

**Answer: No on the hot path.** Evidence:

| Site | Evidence |
|------|----------|
| `fpga_spi.cpp` `sendDdrFrame` | `memcpy` then **`__sync_synchronize()`** before kick (`~1547–1548`) |
| Non-`O_SYNC` maps | Requires `DDR_MEM_FLUSH=1` + `cleanDcacheRange` + second `__sync_synchronize()` |
| `kickDdrDoorbell` | Writes hi, **`__sync_synchronize()`**, magic, **`__sync_synchronize()`** (`~817–819`) — hi-before-magic order |
| `atomic_signal_fence` in arm/host publish | **Only** in `ddr_publish_barrier.hpp` as **documented NEG** (`return false`) |
| Scoreboard | `BankProducerOrder::markPayloadVisible` calls `ddrPublishPayloadBarrier()` (`atomic_thread_fence seq_cst`) before doorbell legal |

**Residual risk (not the signal_fence class):**

- PLXD-absent path uses timed sleep as stand-in for bank free — tear class if
  wrong, but not a missing DMB after memcpy.  
- WriteCombineDriver (future) **must** keep barrier+clean; policy already
  `requires_dcache_flush_before_doorbell=true`.  
- `/dev/mem` strongly-ordered: barrier still documents the edge; map is ordered.

Unit: `test_ddr_publish_barrier` NEG doorbell-before-barrier → tore (rc=0).

---

## 5. Parent one-liner

**YES — fit on BW. M10K OK if wiring clean (scaler ≪ free blocks). Barrier path clean.**  
Unknown only: post-fit efficiency and physical M10K packing of the merged tree.
