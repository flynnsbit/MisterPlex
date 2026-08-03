# Peak vs sustained (npx) + PIX30 development

**Fit scope unchanged:** PIX24 @ 29.7 MHz, macros default OFF.  
**Stale log:** `npx_full_raster_run.txt` removed (pre-fix HARD FAIL contradicted later GREEN).

---

## 1) Peak 40 Mpix/s vs sustained ≥ 29.7

### Peak (measured structure, arithmetic)

Wide-group FIFO (`present_npx_path.sv`): one group/cycle on `clk_sys` into async FIFO.

```
peak = F_sys × PPC = 20e6 × 2 = 40.0 Mpix/s
need_PIX24 = 29.7 Mpix/s   → margin 40/29.7 = 1.347×
need_PIX30 = 37.125 Mpix/s → margin 40/37.125 = 1.077×   (thin)
```

Old serialize wall was **13.33** (accept+unpack on sys) — closed.

### What actually limits *raster* continuity after integration

After `bfa63ac3` / black DE fill:

| Event | FIFO producer | Glass result | Telemetry |
|-------|---------------|--------------|-----------|
| Store hit, on time | active RGB group after `MP_STORE_LAT` | correct pixels | — |
| Store miss / cold line | **black** group still enqueued | black streak / hole | `underrun_count` / frame_miss |
| Async empty mid-DE | unpack stall | tear / freeze CE | **`rd_underrun` → sticky bit15** |

**Critical distinction (do not conflate):**

1. **`rd_underrun` (npx)** = consumer faster than group supply for a phase. Fixed by wide FIFO + prefill + 1000 ppm lead + AF backpressure. Long-haul TB (±1000 ppm, phases) **PASS** at 29.7-class clocks.
2. **Store miss** = DDR/line-cache late. Design **still feeds** the FIFO (black). That is **not** an npx underrun; it is a **content** underrun. Growing the async FIFO does **not** buy correct pixels — only `LINE_COUNT` / DDR BW / prefetch does.

So: a bridge that “holds 40 abstractly” does **not** dip below 29.7 on the FIFO path during DDR refresh **if black fill stays armed**. Refresh shows as **intermittent black/wrong content**, scored on **store** underrun counters — not as silent CE starvation (that path was the forced-zero bug).

### FIFO time cushion (npx only — not multi-line DDR)

Product: `FIFO_AW=6` → **64 groups**, `PREFILL_GROUPS=16`, skid 16.

| Cushion | Groups | Pixels (PPC=2) | Time @ 29.7 MHz | Time @ 37.125 MHz |
|---------|-------:|---------------:|----------------:|------------------:|
| Prefill before first pop | 16 | 32 | **1.08 µs** | **0.86 µs** |
| Full FIFO | 64 | 128 | **4.31 µs** | **3.45 µs** |
| One active line (1280 px) | — | 1280 | **43.1 µs** | **34.5 µs** |

Full FIFO is **~0.1 active line** — enough for Bresenham/phase/CDC gray lag, **not** a multi-line DDR refresh ride. That is intentional: line continuity for **content** is `ddr_frame_store` `LINE_COUNT` (product default **4** → `LINE_SLOTS=8`), not the pixel async FIFO.

### Sustained rate claim — what is proven vs unknown

| Claim | Evidence |
|-------|----------|
| Peak write ≥ 40 Mpix/s structure | RTL: group/cycle wr path |
| Sustained **group cadence** @ PIX24 with ppm/phase | `test_present_npx_longhaul` GREEN |
| Integrated beam→mock-store→tag→npx one frame | `test_present_mp_integrated` GREEN |
| Real `ddr_frame_store` under HPS/DDR3 refresh + writeback arb | **UNKNOWN** — needs cosim or parent glass + `stat_frame_underruns` |
| “Comfortably above 29.7 under all refresh” | **Not claimed** — only: FIFO path not DDR-gated when black fill works; content quality is store-side |

**If parent sees intermittent tear with sticky UR=0:** look at store underrun / LINE_COUNT, not npx depth first.  
**If sticky UR=1:** true producer lag — raise PREFILL/AW or lead, or fix beam `in_ready` upstream.

**M10K/MLAB cost note:** AW=6 already; bump to AW=7 (128 groups, ~8.6 µs @29.7) is cheap insurance for phase, **not** a substitute for line cache. Prefer leave AW=6 until glass shows UR sticky.

---

## 2) PIX30 — full development (fit still PIX24)

### Arithmetic

```
H_TOTAL × V_TOTAL = 1650 × 750 = 1_237_500 pix/frame
clk_pix_30 = 1_237_500 × 30 = 37_125_000 Hz = 37.125 MHz
clk_pix_24 = 1_237_500 × 24 = 29_700_000 Hz = 29.700 MHz
```

### PLL strings (proposed; gated `PRESENT_CLK_PIX_30`, default OFF)

Under existing `PRESENT_CLK_PIX_PLL` (4 clocks, fractional VCO):

| Param | PIX24 (default when PLL on) | PIX30 (`PRESENT_CLK_PIX_30`) |
|-------|----------------------------|------------------------------|
| `output_clock_frequency3` | `"29.700000 MHz"` | `"37.125000 MHz"` |
| `output_clock_frequency0` | 20.000000 MHz | unchanged |
| `output_clock_frequency2` | 90.000000 MHz | unchanged |

RTL: `pll_0002.v` nested ifdef; `present_core` `MP_CLK_PIX_HZ` = 37_125_000 when PIX30.

**Do not enable PIX30 on the held fit.** Second STA grant required.

### Fabric balance @ clk_sys=20, PPC=2

```
peak_sys     = 40.000 Mpix/s
consumer_30  = 37.125 Mpix/s
lead_1000ppm = 37.125 × 1.001 = 37.162 Mpix/s  (rate-match target)
headroom     = 40 − 37.162 = 2.838 Mpix/s  (7.1% of peak)
```

**Honest:** PIX30 **clears** the peak inequality, but margin is **thin** vs PIX24’s 35%. Any systematic >~7% bubble in `beam_ce` (ready low, CE gating) fails long-term. Prefer:

- Keep PREFILL≥16, lead 1000 ppm, skid AF  
- Long-haul TB at 37.125 before claiming sim parity with PIX24  
- If glass/STA tight: PPC=4 (peak 80) or accept content@24 glass delivery

### STA pre-registration (stage1b_pix30) — score, don’t rationalise

**PASS only if all:**

- `Fmax(clk_pix) ≥ 37.125` MHz (Fmax Summary)  
- `Fmax(clk_sys) ≥ 20.0`  
- All constrained setup slack ≥ 0  
- No whole-domain false_path sys↔pix  
- Hierarchy: `u_mp_npx_path`, `u_mp_rate`, `u_mp_beam` nonzero  
- `rd_underrun` / sticky path not stripped  

**FAIL if any of above miss.** On Fmax_pix short: pipeline pix unpack — **never** false_path. On Fmax_sys short from wide word: packing/AW — **never** re-serialize on sys.

**Explicitly unknown until fit:** exact Fmax decimals, worst endpoints.

Related-edge sys/pix remains **async_fifo gray** (same CDC class as PIX24). Period shrinks (26.94 ns vs 33.67 ns) — tighter pix cone, same methodology.

### ARM / product (not fabric-limited if PIX30 STA green)

Parent pre-reg (unfalsified):

```
960×540 path 34.50 ms  vs  33.333 ms @30  → FAIL −1.17 ms
```

If fabric PIX30 STA **PASS**, remaining 30 fps problem is **entirely ARM/tier/PMS** (w-path): fps-aware ladder (854@~27 ms class) or copy DMA — not clk_pix ceiling.

### PIX30 vs ascal

Unchanged: core `CLK_VIDEO` = ascal **input**; HDMI `video_mode` can stay 720p60. 37.125 is content delivery rate into scaler, not VIC-legal output requirement (`ASCAL_VS_CORE_RASTER.md`).

### Commands for parent (when granted)

```bash
# sim balance @ PIX30 clocks (after define PRESENT_CLK_PIX_30 in test)
./tests/unit/test_present_npx_longhaul.sh   # extend or PIX30 variant when wired
# fit (grant only): PRESENT_MULTI_PIXEL + PRESENT_CLK_PIX_PLL + PRESENT_CLK_PIX_30
make post-fit-timing STA_RPT=.../Plex.sta.rpt
# score vs assets/clk_pix_sta_prereg.json stage1b_pix30
```

---

## 3) Summary answers

1. **Peak vs sustained:** Peak 40 is real structure. Sustained **raster groups** at 29.7 are sim-backed with lead/prefill; DDR refresh does **not** gate the FIFO when black fill works — it gates **content**. FIFO depth need not grow “for refresh”; watch **store** UR + LINE_COUNT for intermittent picture holes. True npx UR → sticky bit15.

2. **PIX30:** 37.125 MHz exact; PLL string gated; balance OK but **only 1.077×**; STA floor 37.125 prereg’d; fabric not the 30 fps ARM wall if STA passes. Fit remains **PIX24**.
