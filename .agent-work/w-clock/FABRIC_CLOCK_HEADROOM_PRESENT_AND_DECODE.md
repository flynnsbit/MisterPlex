# Fabric clock headroom — present path + 720p24 decode (w-clock)

**No fit · No device · No PLL apply.**  
**Macro `PRESENT_MULTI_PIXEL` remains default OFF.** CDC contract `e0f23e5a` intact.

Sources of truth:
- PLL: `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` → **clk_sys 20.000 MHz**, clk_ddr 90 MHz  
- STA Fmax (quoted, not re-run here): stub-in **23.46 MHz** (`8fdf440f`); nostub **32.04** (parent live `d1b24e0c`) / **32.59** (`c74c6863` sta.rpt)  
- Multi-pixel path Fmax: **unknown** until integration STA  
- Decode cycle evidence: `docs/decode-throughput.md`, `docs/evidence/cycles_per_mb_breakdown_788aa5f.txt`, `docs/p3-mc-dpb-bandwidth.md`

Parent closed facts this note builds on:
- CPU bank move **~14.97 ms/f @ ~88 MiB/s is structural**; decode+CPU copy cannot meet 720p24.
- **Bitstream ARM→DDR is free** (parent prereg HIT): mean AU ~13.5 kB → 0.146 ms/f; worst keyframe 60 915 B → **0.660 ms/f** vs 41.667. Ingest ~0.32 MB/s. Uncached ceiling is irrelevant to a compressed ring.
- Bottleneck is therefore **fabric decode cycles only** — not data movement.

---

## 1) Present path — what `clk_sys` must be

### 1.1 Pixel / fabric rates (exact)

| Mode | Mpix/s | @1 ppc MHz | @2 ppc MHz | @4 ppc MHz |
|------|-------:|-----------:|-----------:|-----------:|
| Content 720p24 | 22.1184 | 22.12 | **11.06** | 5.53 |
| CEA 720p24 (1650×750×24) | 29.70 | 29.70 | **14.85** | 7.43 |
| Content 720p60 | 55.296 | 55.30 | 27.65 | 13.82 |
| CEA 720p60 (1650×750×60) | **74.25** | 74.25 | 37.13 | **18.56** |

### 1.2 DDR read side (YUV420p bank → line buf)

| Mode | Frame bytes | MB/s sustained |
|------|------------:|---------------:|
| 720p24 | 1 382 400 | **33.18** |
| 720p60 | 1 382 400 | **82.94** |

vs `clk_ddr` peak class 90 MHz × 8 B = **720 MB/s** → 720p60 is **~11.5%** of peak on paper.  
Arbitration with a future fabric decode writer: **unmeasured**. Bandwidth alone does **not** force a `clk_sys` bump; fill runs on **`clk_ddr`**, not `clk_sys`.

### 1.3 Output honesty (MiSTer CE_PIXEL)

One RGB sample per CE with CE=1 ⇒ **output ≤ f_clk_pix**.  
Today multi-pixel ties `clk_pix = clk_sys = 20` ⇒ **≤ 20 Mpix/s** out regardless of PPC  
(≈ **16.16 Hz** at CEA 1650×750 totals). PPC lowers **fabric** group rate only.

### 1.4 Verdict — present path overclock

| Goal | Min fabric clk (PPC) | Ship 20 MHz? | Nostub ~32 MHz? |
|------|----------------------|:------------:|:---------------:|
| 720p24 content touch | 11.06 @2 / 5.53 @4 | **YES** | YES |
| 720p24 CEA fabric work | 14.85 @2 / 7.43 @4 | **YES** | YES |
| 720p60 CEA fabric work | 37.13 @2 / **18.56 @4** | **YES @4 only** | YES @4; FAIL @2 |
| True CEA 24/60 **Hz on glass** | needs **clk_pix** 29.7 / 74.25 | **NO** on ship clk alone | separate PLL plan |

**Plain answer:** For the **present/scan-out fabric engine at ≥2 ppc (720p24) or 4 ppc (CEA 720p60 work rate), the shipping 20 MHz `clk_sys` already covers the arithmetic.**  
**No `clk_sys` overclock is required for present** — *provided* multi-pixel STA still closes at ≥20 MHz (unknown until fit; nostub headroom 32→20 is the only comfort, not a multi-pixel proof).

**Do not bump PLL for present “just in case.”** That would tighten sys↔ddr related-edge (20/90 → 25/90 is 2.22 ns) for no present-rate need.

If integration STA shows multi-pixel Fmax **&lt; 20 MHz**, the fix is **pipeline/path cut or drop PPC**, not a blind 25 MHz hope on a failing cone.

---

## 2) If a bump were required (counterfactual)

| Item | Value | Evidence class |
|------|------:|----------------|
| Shipping constrained | 20.000 MHz | `pll_0002.v` |
| Stub-in Fmax | 23.46 MHz | STA `8fdf440f` |
| Nostub Fmax | 32.04 / 32.59 MHz | parent / `c74c6863` sta |
| Multi-pixel Fmax | **unknown** | needs `Plex.sta.rpt` after macro ON |
| Proposed B_30_90 | 30 MHz | contract only — **not applied** |
| Risk of 25/90 | related-edge 2.22 ns vs ~3.5–3.8 ns data-delay class | `Plex.sdc` / CDC inventory |

**Negative STA slack = hard fail** (`make post-fit-timing`).  
This lane’s recommendation remains: **no bump for present.**

---

## 3) Fabric H.264 720p24 — first-principles clock (do not soften)

### 3.1 Macroblock rate (exact)

```
MB_w = 1280/16 = 80
MB_h = 720/16  = 45
MB/frame       = 80 × 45 = 3600
@ 24 fps       = 3600 × 24 = 86_400 MB/s
@ 25 fps       = 90_000 MB/s
@ 30 fps       = 108_000 MB/s
```

### 3.2 Cycle budget vs candidate clocks

```
cy/MB_budget = f_clk / (MB/frame × fps)
```

| f_clk | @24 fps cy/MB | @25 fps cy/MB | @30 fps cy/MB |
|------:|--------------:|--------------:|--------------:|
| **20 MHz** (ship) | **231.5** | 222.2 | 185.2 |
| 23.46 (stub Fmax) | 271.5 | 260.7 | 217.2 |
| **32.04** (nostub live) | **370.8** | 356.0 | 296.7 |
| 32.59 (nostub sta) | 377.2 | 362.1 | 301.8 |
| 50 MHz (board osc — **not** decode clk) | 578.7 | 555.6 | 463.0 |
| 100 MHz (fantasy / old SDRAM confusion) | 1157 | 1111 | 926 |

**Realtime 720p24 on shipping clk_sys requires the entire decode+writeback path to average ≤ ~231 cy/MB.**

### 3.3 What the tree has actually measured (not 720p, but cost class)

| Evidence | cy/MB | What it is | vs 231 budget |
|----------|------:|------------|---------------|
| `paint_per_mb` frame0 320×240 @ `788aa5f` | **4036.9** | wall paint phase (sink+traverse+diag) | **17.4× OVER** |
| same class 624×480 | **3977.9** | same | **17.2× OVER** |
| Analytical I16 sink subtotal (no CAVLC/win) | **~3173** | `cycles_per_mb_breakdown` | **13.7× OVER** |
| Analytical I4 sink subtotal | **~2195** | same | **9.5× OVER** |
| Aggregate stream_path sim 624×480 | **~259** | **98.7% diagnostic paint** (`decode-throughput.md`) | appears under 480p budget; **illusory** for production |
| Production MC / deblock / DDR WB | **?** | **not implemented / not instrumented** as product cost | will **add** |

Required clock if cost stayed at measured paint class:

```
f_need = cy_per_MB × 86_400
@ 4037 cy/MB → 4037 × 86400 ≈ 349 MHz
@ 3173 cy/MB → ≈ 274 MHz
@ 1000 cy/MB (ambitious serial pipeline) → 86.4 MHz
@ 500 cy/MB (heavy parallel) → 43.2 MHz
@ 370 cy/MB (must beat nostub Fmax) → 32.0 MHz  ← equal to nostub ceiling
@ 231 cy/MB (ship 20 MHz) → 20.0 MHz
```

Cyclone V on this board has **no** credible path to 100–350 MHz full H.264 on `clk_sys`.  
Nostub **~32 MHz** is the best **empty-of-stub** sys Fmax on record — and **re-inserting** a real decode island will **pull Fmax down** (stub historically bound at 23.46). So planning at 32 MHz cy/MB budget (**~371 cy/MB @24**) is already **optimistic**.

### 3.4 Parallelism required (order-of-magnitude)

To hit **≤231 cy/MB** from a **~3000 cy/MB serial sink**:

```
speedup ≈ 3000/231 ≈ 13×
```

That is not a PLL bump. It is **multi-block / multi-transform / wide MC + coalesced DPB**, on-chip line/DPB structure, and almost certainly a **decode-optimized domain** after path cuts — or accepting that **full 720p24 baseline intra+inter on this part is not a 20 MHz serial machine**.

DPB bandwidth (`docs/p3-mc-dpb-bandwidth.md`): even at **480p25**, raw byte-serial DPB alone was shown to **exceed** the 684 cy/MB budget; 64-bit coalesce was required to fit. **720p24 multiplies MB rate by 3600/1170 ≈ 3.08×** vs that 480p25 case → DPB pressure **harder**, not easier.

### 3.5 Buildability verdict (plain — bitstream free does not change this)

Parent moved the programme bottleneck from uncached **pixel** move to **decode**. That is the right architecture. Clock arithmetic for the decoder is unchanged by free bitstream ingest:

| Question | Answer |
|----------|--------|
| Is 720p24 fabric decode *clocked away* at 20–32 MHz with today’s serial cost class (~2k–4k cy/MB)? | **NO. Wall.** Need ~100–350 MHz class — unreachable as full-decode `clk_sys` on this part. |
| Is it *buildable at all* on DE10-Nano Cyclone V? | **Only if average ≤ ~231 cy/MB @20 (or ≤ ~371 @32 nostub optimistic).** That is a **≥10× architecture** problem (parallel MB/transform/MC, coalesced DPB, strip the diagnostic paint tax), **not** a PLL story. |
| Does free bitstream / ring ABI make the wall softer? | **No.** 0.66 ms/f worst AU leaves almost the entire 41.667 ms for fabric. The wall is **cycles/MB**, not bytes across HPS. |
| Does existing RTL *feature-match* PMS Constrained Baseline (CAVLC, I/P, no B, no CABAC)? | **Yes on paper** (parent inventory: syntax/CAVLC/intra/inter/MC/deblock/DPB/IQ-IDCT; CABAC=0). **Not** realtime or fit proof. |
| Does existing `.sv` / bit-exact close realtime 720p24? | **No.** Correctness ≠ cycles. None fitted/timed vs real stream yet (parent). |
| Is missing CABAC the clock wall? | **No for current PMS path.** Wall remains **≤231 cy/MB @20**. Profile pin = **w-path**. |
| Should the fleet invest weeks on “raise clk_sys”? | **No.** Invest on **cy/MB architecture** inside a **20–32 MHz** band. Clock is a secondary lever after path cuts, not the plan. |

| Claim | Verdict |
|-------|---------|
| Present @2–4 ppc needs clk_sys &gt; 20 | **FALSE** (rate arithmetic); STA of wider path still unknown |
| Present needs clk_sys overclock before integration | **NO** |
| Fabric 720p24 decode fits in 20 MHz at today’s measured ~4k cy/MB | **FALSE — wall** |
| Fabric 720p24 decode fits if we only “raise clock to nostub 32” | **FALSE** unless cost ≤ ~371 cy/MB (**~11×** better than measured paint class) |
| 720p24 fabric decode is impossible forever on DE10-Nano | **Not proven** — but it is **impossible without a redesign that buys ~10×+ throughput**, not a PLL tweak |
| Bit-exact / existing decode RTL proves realtime 720p24 | **FALSE** — correctness ≠ cycles; fit/STA/stream still open |
| Feature set matches PMS Constrained Baseline (no CABAC needed) | **TRUE on inventory** — does **not** remove cy/MB wall |
| Bitstream free ⇒ decode clock problem is solved | **FALSE** — movement ≠ decode |

**If the fleet is about to invest weeks assuming “clock it up and 720p24 fabric decode closes,” stop.** The arithmetic says the investment must be **parallel architecture and memory subsystem**, with clock as a secondary lever inside a ~20–32 MHz band.

**w-clock programme decision for parent:** treat **86 400 MB/s → 231 cy/MB @ ship clock** as the hard acceptance budget for any fabric decode proposal. Anything that cannot show a path to that budget (or a measured multi-MB parallel design that lands there) is **not** a 720p24 plan.

---

## 4) What parent should run

```bash
# Pre-fit arithmetic (no device) — this worktree
make present-720p-fit-contract
make multi-pixel-present-contract
./tests/unit/test_present_720p_fit_contract.sh   # true rc direct
python3 scripts/check_fabric_clock_headroom.py --root .

# After exclusive integration fit (parent only)
make post-fit-timing STA_RPT=path/to/Plex.sta.rpt
make post-fit-timing-margin STA_RPT=path/to/Plex.sta.rpt
# Quote Fmax Summary for general[0] — multi-pixel ON netlist only is evidence
```

---

## 5) Bottom line (one paragraph)

**Present:** shipping **20 MHz is enough** for 720p24 fabric work at 2 ppc and for CEA 720p60 *work rate* at 4 ppc; DDR 33–83 MB/s is not the clk_sys driver; true 24/60 Hz glass still wants a faster **clk_pix**, not a clk_sys hero bump. **Decode:** PMS Constrained Baseline **feature-matches** existing CAVLC RTL (no CABAC needed) — that is good architecture news and **does not** clear the rate wall. 86 400 MB/s @720p24 still leaves **~231 cy/MB @20 MHz**; measured/analytical serial costs are **thousands** of cy/MB → **order-of-magnitude short**. Do not plan 720p24 fabric decode as an overclock story.
