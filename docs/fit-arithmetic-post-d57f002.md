# Fit arithmetic after d57f002 (verified, units disciplined)

**Date:** 2026-07-30 · **Owner:** sv-integrate  
**Sources:** coord-map-d57f002 (`true rc=0`), coord-map1 product, isolated dequant/had maps  
**Device:** 5CSEBA6 — **41,910 ALMs · 112 DSP · 5,662,720 block bits (553×10,240)**

## 1. Measured now (quoted)

| Quantity | Value | Unit | Source |
|----------|------:|------|--------|
| Whole design ALMs needed | **63,199** | map ALMs | d57f002 map.rpt |
| Device ALMs | 41,910 | ALMs | device |
| Ratio | **1.51×** | | 63199/41910 |
| Whole DSP | **149** | DSP blocks | d57f002 summary |
| Whole block bits | **3,063,245** | bits | d57f002 summary |
| Product-only (map1) ALMs needed | **21,645** | map ALMs | coord-map1 |
| Product-only DSP | **74** | | coord-map1 |
| Product-only bits | **2,997,709** | | coord-map1 |

### Probe entity table (Combinational ALUTs — **not** ALMs)

| Entity | comb ALUTs (self) | DSP | mem bits |
|--------|------------------:|----:|---------:|
| map_decode_area_probe | 56,077 (38) | 97 | 65,536 |
| h264_i_res_recon_sink | **38,687** (22,064) | **64** | 0 |
| h264_p_mb_traverse | 9,167 (7,079) | 1 | 65,536 |
| h264_recon_frame_store | 6,413 | 0 | 0 (async uninfer) |
| h264_i16_dc_hadamard (probe leaf) | 1,556 | 32* | 0 |
| h264_recon_export | 216 | 0 | 0 |
| h264_byte_ram_sp | 0 | 0 | **65,536 M10K** |

\*See §3: isolated had is **3 DSP**, not 32.

## 2. Parent’s ~29k / ~97 DSP check — what is valid

### 2.1 DSP path (valid arithmetic, same units)

Map-tree DSP budget (probe includes **extra** standalone `u_had` outside sink):

```
whole DSP                         149
sink entity DSP                   -64
sink after serial-IQ target       +12
                              -------
map-tree residual DSP              97
```

**97 DSP < 112** — under the device if that substitution holds.

**Product-intent** (one had inside sink, no double probe leaf):

```
product DSP                        74
+ traverse                         +1
+ sink @ ≤12 DSP                  +12
                              -------
product-intent DSP                 87
```

**87 DSP < 112**. Parent’s **~97** is the map-tree form; **~87** is the cleaner product form. Both clear 112 **if** sink truly lands ≤12 DSP inclusive of dequant+had+chroma IQ.

### 2.2 ALM path — parent ~29k mixes units (REJECT as written)

Suspected parent steps (reconstructed):

```
63199 ALMs needed  -  38687 comb ALUTs  +  4000 ALM target  ≈  28512 ≈ "29k"
```

**That subtraction is invalid:** map **ALMs needed** and entity **comb ALUTs** are different units.  
We have enforced this since the ALUT/ALM audit. **Do not publish 29k as measured.**

### 2.3 What we can say about ALMs (proxy + composition, labelled)

**A. Comb-fraction proxy of probe ALM delta** (estimate, not a map number):

```
probe ALM delta ≈ 63199 − 21645 = 41554 map ALMs
sink share of probe comb ≈ 38687 / 56077 ≈ 69.0%
sink ALM proxy now ≈ 0.690 × 41554 ≈ 28,670 map ALMs
after sink → 4000 ALMs:  whole ≈ 63199 − 28670 + 4000 ≈ 38,500 map ALMs
```

**~38.5k ALMs** (proxy) vs device 41.9k → **possible under**, thin margin, **not proven**.

**B. Composition if traverse also hits ≤3k ALMs and RFS stops being 6.4k comb fabric:**

```
product                  21,645
+ traverse @ gate         3,000   (currently MISS — 7079 self comb)
+ sink @ target           4,000
+ RFS after M10K fix        ~500  (hope; now 6413 comb + 0 bits)
+ had/export residual       ~500
                        -------
                         ~29,600 map ALMs
```

**~29k appears only if traverse AND sink AND RFS all hit targets together.**  
Sink-alone diet → **~38k proxy**, not 29k.

**C. Required next measurement:** one map after sink freeze (and preferably RFS registered read). No more ALUT−ALM arithmetic.

## 3. DSP baselines (isolated maps — measured)

| Module | Pre-reg DSP | Measured DSP | ALMs needed | rc | Score |
|--------|------------:|-------------:|------------:|---:|-------|
| `h264_dequant4x4` parallel | 16 | **17** (16× two-indep 18×18 + 1) | **240** | 0 | near-HIT |
| `h264_i16_dc_hadamard` | 32 (from entity) | **3** | **247** | 0 | **MISS entity 32** |

Evidence: `.agent-work/integ-wiring/dequant_dsp.map.summary`, `hadamard_dsp.map.summary`.

**Implications for serial-IQ:**

- One parallel dequant alone is **17 DSP > 12** sink budget → **serial dequant is mandatory**.
- Hadamard is **cheap in isolation (3 DSP)**; entity “32 DSP” was **context/attribution**, not a hard floor for a serial redesign.
- Sink entity **64 DSP** still includes in-tree dequant packing (**32 DSP** child in d57f002 vs **17** isolated) — **DSP drifts under integration**; the freeze map is the only number that counts for the ≤12 gate.

Serial-IQ target **≤12 DSP for whole sink** remains the right gate; floor from isolation: dequant serial ~1–2 + had ~0–3 + glue ≪ 12 if truly resource-shared.

## 4. M10K budget after traverse RBSP + planned sink/RFS

| Item | Bits | Notes |
|------|-----:|-------|
| Device | **5,662,720** | 553 × 10,240 |
| d57f002 whole (now) | **3,063,245** | 54.1% — includes RBSP M10K 65,536 |
| Headroom now | **2,599,475** | **45.9% free** |
| RBSP (done) | 65,536 | M10K SDP inferred |
| RFS 300 MB I420 analytical | **921,600** | currently **0 bits** (async uninfer → 14k regs) |
| sink `top_row[0:1023]` | 8,192 | tiny if SDP M10K |
| sink planes 256+64+64 B | ~3,072 | stay regs (below M10K efficiency) |
| **After RFS+top_row as M10K** | **~3,063,245 + 921,600 + 8,192 ≈ 3,993,037** | **~70.5%** of device |
| Headroom then | **~1,669,683** | **~29.5% free** |

**M10K is not the wall** if RFS/top_row use textbook registered SDP (same pattern as `h264_byte_ram_sp`).  
Risk: many shallow banks / dual-read replication (dualrd probe used **2×** bits). Prefer 1R1W time-mux.

RFS must fix **async read (276007)** or bits stay 0 and ALMs stay high — same lesson as combo probe C.

## 5. Buildability statement (updated honest framing)

*The decoder is bit-exact on two clips (d57f002: 300/300 and 1170/1170).  
After one RBSP memory restructure, the design went from ~30× oversized to **1.51×** on map ALMs needed (1,241,952 → 63,199), with **M10K RBSP inferred** (Info 276029, 65,536 bits).  
A single remaining module class — the **sink** (and its parallel IQ / neighbour fabric), plus RFS async-read debt — stands between the design and fitting on both ALMs and DSPs.  
Parent “~29k ALMs if sink hits 4k” is only valid as a **multi-target composition** (sink+traverse gate+RFS), not as `whole_ALMs − sink_comb`. DSP path to **~87–97 < 112** is on firmer ground.  
**Next number that decides the programme:** map of sink freeze against ≤4,000 ALMs and ≤12 DSP.*

## 6. Map slot

sv-integrate holds the next **one** `quartus_map` for the sink freeze SHA from `sv-traverse`.  
No competing Quartus. No fit/RBF/deploy.

---

## 6. SUPERSEDED by cf6842a map (2026-07-30) — measured serial-IQ

**Source:** `docs/coord-map-cf6842a-ALMS.txt` · `true rc=0` · **PROVISIONAL** until cf6842a score+RED.

| Quantity | d57f002 | **cf6842a** | Unit |
|----------|--------:|------------:|------|
| Whole ALMs needed | 63,199 | **61,267** | map ALMs |
| Ratio vs 41,910 | 1.51× | **1.46×** | |
| Whole DSP | 149 | **111** | DSP |
| Whole bits | 3,063,245 | **3,063,245** | bits |
| sink comb (self) | 38,687 (22,064) | **39,155 (23,211)** | comb ALUTs |
| sink DSP | 64 | **4** | DSP |
| traverse comb (self) | 9,167 (7,079) | **8,682 (6,574)** | comb ALUTs |
| serial dequant DSP | n/a | **2** | DSP |
| serial had DSP | n/a | **2** | DSP |
| i16 pred in sink | ~9–10k | **10,643** | comb ALUTs |

### Parent ~29k ALMs after serial-IQ — still REJECT as achieved

Serial IQ **did not** move sink comb (~39k flat). Whole ALMs **61,267** still **1.46×** device.  
~29k required an ALM diet that **did not happen**. Remaining wall: sink self + `h264_intra16x16_pred` (10,643) + idct/planes as regs (bits=0).

### Parent ~97 DSP — directionally confirmed; product-intent better

```
whole map DSP                         111   (≤112 PASS on this composition)
  of which probe total                 37   (parallel had 32 + sink 4 + trav 1)
product-without-probe proxy       111−37 = 74
retire stub parallel dequant (−32) + serial sink already in probe path:
  cleaner product-intent when stub drops parallel dequant ≈ 46 DSP  << 112
```

**sink DSP 4 ≤ 12: PASS.** dequant isolate baseline (17) is **retrospective** — skip further ceremony.

### M10K headroom (unchanged)

3,063,245 / 5,662,720 used (54%). +RFS 921,600 → ~70%. Sink arrays still **uninferred** (0 bits). Not the wall.

### Honest sentence (post-cf6842a)

Bit-exact I-decoder (lane scores on ancestors) + traverse M10K took the design **29.6× → ~1.5×**.  
Serial IQ solved **DSP** (sink 64→4; whole 149→111). **ALMs still ~1.46×** — one module (sink fabric/pred/planes), not the mul farm, still blocks fit.
