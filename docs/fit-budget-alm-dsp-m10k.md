# Fit budget: ALM + DSP + M10K (unsoftened)

**Device:** Cyclone V `5CSEBA6` (DE10-Nano)  
**Caps (Intel handbook / Quartus device):**

| Resource | Device total | Notes |
|----------|--------------|--------|
| ALMs | **41,910** | post-fit is truth; map “Estimate of ALMs” ≈ directionally |
| 18×18 DSP | **112** | **hard count** — cannot trade for cycles without redesign |
| M10K blocks | **553** | 10,240 bits each |
| Block memory bits | **5,662,720** | = 553 × 10,240 |

**Evidence freezes:** product map1 `7a9cb598` · decode probe map2d · chroma map3b `1e1fbe1`  
**wire6 post-fit (historical):** ALMs 21,021 (50%), DSP 74, setup +0.283 — RBF not redeployed.

---

## 1. Measured baselines (quoted)

| Pass | ALMs needed (map) | DSP | Block mem bits | Notes |
|------|-------------------|-----|----------------|-------|
| coord-map1 product | **21,645** | **74** | **2,997,709** (53%) | identity deblock, serial MC |
| coord-map2d + decode probe | **1,241,952 ALMs needed** | 149 | 2,997,709 | traverse **1,180,271 comb ALUTs**; ~29.6× device ALMs |
| coord-map3b + chroma/sink | **48,436** | **154** | 2,997,709 | sink+chroma kept; no traverse |
| wire6 post-fit | 21,021 | 74 | (fit rpt) | BUILD_OK historical |

Map1/3 report **~64 ALTSYNCRAM “M10K block” lines** in the megafunction list (not 1:1 with physical blocks — packing merges). **Bits are the planning unit;** physical M10K ≈ ceil(bits/10240) as a lower bound, higher if shallow/wide ports pack poorly.

**Product memory already:** 2,997,709 / 5,662,720 ≈ **52.9%** of bit budget **before** decode RBSP/RFS/neighbors.

---

## 2. DSP is the binding constraint today

```
product (map1)     74 DSP
sink path (map3b)  92 DSP   (u_dq 52 + u_had 32 + chroma_dc 8 + …)
sum if stacked    166 DSP
device              112 DSP
→ OVER BY ~54 DSP even if traverse ALMs were free and sink ALMs were free
```

**Why sink DSP is high (quoted RTL, not guess):**  
`h264_dequant4x4` builds **both** max16 and max15 lanes as parallel `dequant_one()` wires (up to ~31 multiplies of `coeff*qmul`), not one shared multiplier.  
`h264_i16_dc_hadamard` adds another wide mul plane (**32 DSP** in map3b).  
map2d sink DSP **64** vs map3b **92**: same module class, **more of the mul tree kept** when chroma/had paths + stronger keep are present — **DSP number drifts with elaboration, so plan to the serial target, not the transient map column.**

**ALMs trade for cycles. DSPs do not** unless the mul tree is serialised or replaced with shift-add.

**Hard product DSP envelope (proposal):**

| Bucket | DSP cap |
|--------|---------|
| MiSTer framework + present + ascal + audio | (inside today’s 74) |
| Serial MC (luma/chroma) | keep ≤ current share |
| **Decode IQ/IDCT/Hadamard total** | **≤ 12** (one shared dequant mul + small had) |
| Chroma DC scale | prefer shift-add; ≤ 2 if mul |
| Deblock (future) | 0 preferred |
| **Whole chip** | **≤ 100** (12 headroom for packing/surprise) |

---

## 3. ALM arithmetic (current vs after crash-diet targets)

### 3.1 Current (cannot fit)

```
device                         41,910
product                        21,645
h264_p_mb_traverse          1,180,271   ← localised bomb
h264_i_res_recon_sink          40,456   ← localised bomb
chroma leaves (qp/dc/chr8)        ~900  ← fine
deblock serial prior           25,433   ← fourth priority
────────────────────────────────────
sum ≫ 41,910   (~30×)   CANNOT FIT
```

### 3.2 After targets (aspirational — must re-map)

| Block | Target ALMs | Target DSP | Target M10K bits (add) |
|-------|-------------|------------|-------------------------|
| product shell (hold) | 21,645 | 74 → **≤ 70** after IQ share | 2,997,709 hold |
| traverse serial | **≤ 3,000** | ≤ 2 | RBSP 8–16KB → **65,536–131,072** bits |
| sink serial | **≤ 4,000** | **≤ 12** | top_row 320 + chroma tops + plane optional **~5–15k** bits |
| chroma leaves | ≤ 1,000 | ≤ 2 | ~0 |
| RFS 300 MB I420 | ≤ 500 logic | 0 | **921,600** bits (~90 M10K if 1:1) |
| deblock real | ≤ 2,500 or stay identity | 0 | small linebufs |
| **sum ALMs** | **≤ ~33k** | **≤ ~86** | see §4 |
| headroom | ~9k ALMs | ~26 DSP | M10K §4 |

**Only after map confirms traverse≤3k and sink≤4k/12DSP** does deblock return to the queue.

---

## 4. M10K / block-RAM budget (next binding constraint)

### 4.1 Already consumed (product map bits)

| | Bits | % of 5,662,720 |
|--|------|----------------|
| Product total | **2,997,709** | **52.9%** |
| Remaining | **2,665,011** | **47.1%** |

Dominant existing users (from map megafunction list): `ddr_frame_store` line buffers, `ascal`, bitstream FIFO, DPB/MC windows, audio FIFO — **present path is expensive in RAM.**

### 4.2 Decode-path additions if done as M10K (analytical)

| Structure | Bits (formula) | ≈ M10K @ 10kb | Notes |
|-----------|----------------|---------------|-------|
| RBSP 8 KiB | 8,192×8 = **65,536** | ~7–16 | 16 KiB → 131,072 |
| res_win 64 B | 512 | 1 | may stay regs |
| tc_top / i4_mode_top / chr tops | ~ few k | 1–4 | traverse neighbors |
| sink `top_row` 320 | 320×8 = **2,560** | 1 | use 320 not 1024 |
| sink `top_u/v` 160 each | 2×160×8 = **2,560** | 1 | |
| plane_y/u/v MB | 384×8 = **3,072** | 1 | or regs |
| **RFS full frame 300 MB** | 300×384×8 = **921,600** | **~90–120** | **largest decode add** |
| serial MC (already in product) | in the 3.0M | — | already paid |
| deblock linebufs (future) | tens of k | few | |

### 4.3 Remaining bits after decode M10K plan

```
remaining after product           2,665,011
− RFS 921,600                     1,743,411
− RBSP 16KB 131,072               1,612,339
− neighbors+tops+plane ~20,000    ~1.59M bits free
```

**Bits: RFS + RBSP fit in remaining 47% with ~1.6M bits headroom** if inference is clean.  

**Physical M10K packing risk:** shallow dual-port and many small banks burn **extra blocks**.  
**Pre-register for next full map:** decode adds **≤ 150 M10K blocks** physical; fail if total bits &gt; 90% or fitter reports M10K exhaustion.

### 4.4 What would break M10K

- RFS **uninferred as regs** (async read) → register explosion (already seen Error 276003).  
- RBSP left as logic mux → ALM bomb, not M10K.  
- `MAX_PIC_W=1024` tops × many ports → fat mux or fat RAM. **Product must pin 320.**  
- Second full-frame store “for convenience” → another 900k bits — **do not**.

**RFS policy:** one frame store, registered SDP M10K, MB_COUNT=300 for 320×240; larger clips need DDR-backed store (export path), not a second on-chip frame.

---

## 5. DSP drift 64 → 92 (planning rule)

| Observation | Rule |
|-------------|------|
| Same sink RTL, different keep/elaboration → different DSP column | **Never treat map DSP as stable until IQ is serial** |
| Parallel `m15_*` and `m16_*` both elaborated | Serial index 0..15 **one** `dequant_one` |
| Hadamard 32 DSP | Serial 2×2/4×4 butterflies or one mul lane |
| Product already 74 DSP | Decode must **reuse** product dequant instance or cut product stub IQ when sink owns IQ |

**Integrate gate:** any claim “sink DSP ≤ 12” requires **map entity line** on a freeze SHA, not a hand estimate.

---

## 6. Ownership (sink) — integrate recommendation

**`sv-traverse` implements the sink crash-diet** (owns `h264_i_res_recon_sink.sv`, correctness).  
**`sv-integrate`** measures + serial-IQ brief; **`sv-mvd`** patch-only on chroma ports.  
See `docs/cycle-iterative-sink-area.md` §0.

## 7. Measurement gate (integrate owns)

1. One coordinated `quartus_map` per freeze; no lane self-fits.  
2. Publish ALMs estimate + DSP total + block mem bits + per-module table.  
3. Pre-register before measure; publish HIT/MISS.  
4. Soft-skip / UNSCORED ≠ pass.  
5. `true rc` captured directly.

**Next maps (planned, not run until freeze SHA):**  
- **map-traverse-serial** when `sv-traverse` posts SHA  
- **map-sink-serial** when sink implementer posts SHA  
- **map-stack** product+traverse+sink+chroma leaves (no deblock)

---

## 8. Exact-source gap — CLOSED at d57f002

coord-map-d57f002 (`docs/coord-map-d57f002-ALMS.txt`): freeze **d57f002** re-scored
300/300 and 1170/1170 on the same tree that mapped.
- `h264_byte_ram_sp` **M10K inferred** (65536 bits, Simple Dual Port) — RAM summary, not ALM guess
- traverse **9,167 comb ALUTs** (self 7,079) vs map2d **1,180,271** (~129×)
- whole ALMs needed **63,199** vs **1,241,952** (was 29.6× device → **1.51×**)
- DSP still **149**; sink **38,687 comb + 64 DSP** still blocks fit
- ≤3000 ALM gate: entity ALMs absent at map; self comb 7079 → not a clean ALM PASS

## 8b. Prior exact-source note (attrs-only map2b) — superseded


coord-map2b traverse/sink are **not byte-identical** to score SHAs:
- `6dc5993` traverse sha256 `d076328e…` vs mapped `d5245c65…` — **only** added `(* ramstyle="M10K" *)` on rbsp/i4_mode_top/tc_top (and those still **uninferred**).
- sink mapped from chroma era / patches ≠ pure `6dc5993` byte image; map3b used `1e1fbe1` sink.

**NUMBER STANDS** for the architecture (dynamic-index bomb + hierarchy reconcile).  
**Still owed:** one map on **byte-exact** freeze after serial redesign (area + 300/300 + 1170/1170 same SHA).

## 9. Honest one-liner (corrected phrasing)

*Functionally exact I-decoder in simulation; synthesis succeeds; design **cannot fit** this FPGA **in its current architecture** (~29.6× on map ALMs needed vs 41,910) — cause localised to **64 parallel dynamic RBSP reads** (traverse) + sink parallel IQ/planes; chroma leaves cheap; DSP overbooked even without traverse; `ramstyle` alone will not save you; M10K bits look survivable only after real inference.*
