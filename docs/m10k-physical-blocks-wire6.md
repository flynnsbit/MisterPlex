# Physical M10K **blocks** (not bits) — MAP/INTEGRATION report

**SOURCE of truth for shipping:** post-fit `product-wire6`  
RBF md5 `14eaeff3270a6f59a434e0f777ed823d` (live device, EVIDENCE file).  
**No new fit run.** Numbers below are quoted from existing reports.

Device: Cyclone V `5CSEBA6U23I7` — **553** M10K blocks × 10,240 bits = 5,662,720 bits  
(`docs/fit-budget-alm-dsp-m10k.md:10-11`).

---

## 1. Shipping composition — physical blocks (FIT, not map)

Quoted `product-wire6` `Plex.fit.rpt` Fitter Summary:

```
; Logic utilization (in ALMs)     ; 21,021 / 41,910 ( 50 % )
; Total block memory bits         ; 2,997,709 / 5,662,720 ( 53 % )
; Total RAM Blocks                ; 465 / 553 ( 84 % )
; Total DSP Blocks                ; 74 / 112 ( 66 % )
```

Also Fitter Resource Usage Summary:

```
; M10K blocks                                                 ; 465 / 553             ; 84 %
```

| Metric | Value |
|--------|------:|
| Physical M10K used | **465** |
| Physical M10K free | **88** |
| Bit capacity used | 53% |
| Bit capacity “free” | **47%** ← **misleading unit** |

**Finding:** bits say ~half free; **blocks say only 16% free (88 blocks).**  
The “~46% M10K free” figure used after the 788aa5f map was **bit-capacity arithmetic** (`5,662,720 − 3,073,485 = 2,589,235 ≈ 45.7%`). **It is not physical block headroom.** MAP lane relied on that bit figure in `docs/coord-map-788aa5f-ALMS.txt` — **that guidance is retired for packing decisions.**

---

## 2. Where the 465 blocks go (Fitter RAM Summary, col `M10K blocks`)

Parsed from `Plex.fit.rpt` Fitter RAM Summary (header line with `M10K blocks` field).  
Row sum of per-instance M10K = **467** (off-by-2 vs summary 465 — packing/share; **use summary 465**).

| Group | Physical M10K | Notes |
|-------|-------------:|-------|
| `dpb_mem` (stub) | **256** | 2,097,152 impl bits · **80.0%** of 256×10240 |
| `ddr_frame_store` line_buf ×48 | **96** | 159,744 bits · **16.2% eff** · ideal ceil(bits/10k)=16 → **6.0× waste** |
| `ascal` | **43** | mix; some 4k-bit RAMs at **10%** eff (4 blocks each) |
| `bitstream_fifo` | **32** | 262,144 bits · 80% eff |
| other / osd / audio / shadow | **~40** | includes tiny shift-taps at **~1%** eff |
| **u_rbsp_ram** | **ABSENT** | not in shipping wire6 |
| **u_plane_y** | **ABSENT** | not in shipping wire6 |
| **u_top_row** | **ABSENT** | not in shipping wire6 |
| **u_tc_top / u_i4_mode_top** | **ABSENT** | not in shipping wire6 |
| **u_recon_store** | **ABSENT** | not in shipping wire6 |

### Efficiency trap (quoted, not guessed)

`ddr_frame_store` line buffers alone prove the parent’s point:

- 48 instances × **2 M10K each** typical (39×64 or 78×64 configs)
- **96 blocks** to hold **159,744 bits** (~16% of 96×10240)
- Same bits packed ideally ≈ **16 blocks**

**Small / shallow / wide arrays burn whole blocks.** Bit-% free does not survive contact with the fitter.

Top single consumer still `dpb_mem` at 256 blocks (large and relatively efficient). Framework RAM is the block wall, not decode byte_rams — **on the shipping tree those decode rams are not present yet.**

---

## 3. Decode conversions — what maps actually show

### 3.1 Map cannot quote Total RAM Blocks

`quartus_map` reports **block memory bits** and RAM Summary type/depth/width/bits.  
It does **not** emit `Total RAM Blocks ; N / 553`.  
**Physical block counts for map-only trees are unknown until fit** — analytical lower bound only: `ceil(bits / 10240)`, and wire6 proves real cost can be **several ×** that for shallow ports.

### 3.2 `788aa5f` probe map (luma-only + `map_decode_area_probe`)

`coord-map-788aa5f` `Plex.map.rpt` — bits total **3,073,485**; **no physical block total**.

| Array | Depth×Width | Bits | Type (map) | Info 276029 | LB blocks `ceil(bits/10k)` | Physical blocks |
|-------|-------------|-----:|------------|-------------|---------------------------:|-----------------|
| `u_plane_y` | 256×8 | 2,048 | M10K block | YES (under probe sink) | **≥1** | **unknown (no fit)** |
| `u_top_row` | 1024×8 | 8,192 | M10K block | YES | **≥1** | **unknown** |
| `u_rbsp_ram` | 8192×8 | 65,536 | M10K block | YES | **≥7** | **unknown** |
| `u_tc_top` | — | — | — | not on this SHA | — | — |
| `u_i4_mode_top` | — | — | — | not on this SHA | — | — |

Analytical **minimum** decode add if these pack ideally: **1+1+7 = 9 blocks**.  
**Upper bound unknown without fit.** If they pack like line_buf class, cost multiplies.

Retired line from 788aa5f write-up: “free 2,589,235 (~46%)” as M10K headroom — **bits only**.

### 3.3 Product-only map `4f281e6` (no probe)

`coord-map-product-4f281e6` `Plex.map.rpt` — bits **3,233,741**; **no physical block total**.

| Array | Depth×Width | Bits | 276029 | LB blocks | Physical |
|-------|-------------|-----:|--------|----------:|----------|
| `u_rbsp_ram` | 16384×8 | 131,072 | YES | **≥13** | unknown |
| `u_tc_top_ram` | 256×6 | 1,536 | YES | **≥1** | unknown |
| `u_i4_mode_top` | — | 0 | **NO** (DCE; never-read) | 0 | n/a |
| `u_plane_y` / `u_top_row` | — | 0 | **NO** (sink DCE on this elab) | 0 | n/a |
| `u_recon_store` | — | 0 | **NO** | 0 | n/a |
| `dpb_mem` | 262144×8 | 2,097,152 | YES | ≥205 | wire6 fit = **256** |

---

## 4. Remaining block headroom — shipping + chroma

### Shipping (wire6 fit) — measured
- **88 physical M10K free**
- ALMs 50% free-ish; DSP 38 free (112−74); **blocks are the tight memory resource**

### Can chroma merge fit in 88 blocks?
**Unknown as a fitted number** (no merged fit authorised). Bound from evidence:

| Candidate add | Bits (doc/map) | LB blocks | Risk |
|---------------|---------------:|----------:|------|
| Already-planned RFS 300 MB I420 | 921,600 | ≥90 | **≥90 > 88 free alone** if on-chip M10K (`fit-budget` §4.2) |
| RBSP 8 KiB (788 style) | 65,536 | ≥7 | must be paid when traverse ships |
| RBSP 16 KiB (4f product) | 131,072 | ≥13 | |
| plane_y + top_row | ~10k | ≥2 | small; still ≥1 block each |
| tc_top 256×6 | 1,536 | ≥1 | **classic 5–15% efficiency trap** if 1 full block |
| chroma tops/planes (u/v) | ~same order as luma tops | ≥2–4 LB | |
| wire6-style packing tax | — | **×2–6 on shallow** | measured on line_buf |

**Defensible statements:**
1. Shipping has **88 M10K blocks** left — not ~250 “bit-equivalent” blocks.
2. **On-chip full-frame RFS at 300 MB is block-infeasible on residual 88** under ideal packing (≥90), worse if packing is poor. DDR-backed store remains the policy in `fit-budget` §4.4.
3. Chroma **neighbor/plane M10Ks** are few blocks LB but each small array can still take **1 whole block**; do not mint many shallow banks.
4. **Chroma merge block fit: unknown until a fit of the merged tree** — map bits cannot clear it. Pause further M10K conversions is correct until a packing plan exists.
5. Largest shipping block hog is **`dpb_mem` 256** + **present path 96+43+…** — decode byte_ram conversions are not yet on the live RBF.

---

## 5. Misses published (MAP lane)

| Prior claim | Reality |
|-------------|---------|
| “~46% M10K free” after 788aa5f | **Bit free % only**; shipping fit is **16% blocks free (88/553)** |
| Bits are the planning unit (`fit-budget` § note) | **Insufficient** — post-fit blocks bind first on this device |
| Decode M10K wins “use free M10K” | Those arrays **are not on wire6**; cost when integrated is **≥ LB blocks**, packing TBD |
| plane_y 2048 bits “cheap” | Still **≥1 physical block** (20% of one M10K if alone) |

---

## 6. Artifacts

| Path | Role |
|------|------|
| `.agent-work/integ-wiring/product-wire6-EVIDENCE.txt` | 465/553 quote + deploy md5 |
| `/home/flynnsbit/mplex-builds/product-wire6/.../Plex.fit.rpt` | Fitter Summary + Fitter RAM Summary |
| `docs/coord-map-788aa5f-ALMS.txt` | map bits; **bit-% free retired below** |
| `docs/coord-map-product-4f281e6-ALMS.txt` | product map; no block total |
| This file | block-unit report |

**No FIT authorised. No RBF. No deploy.**
