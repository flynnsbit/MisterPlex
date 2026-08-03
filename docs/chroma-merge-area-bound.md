# Chroma merge area/DSP bound (post-cf6842a)

**Owner:** sv-integrate · **Date:** 2026-07-30  
**Status:** estimate only — **no map of merged tree yet**. Next map slot reserved for
`rtl/chroma-intra` **rebased onto cf6842a** after re-score.

## 1. What cf6842a / d57f002 actually measured

Both integrate maps are **luma-only decode-path probes**:

| Map | Whole ALMs needed | DSP | bits | Tree |
|-----|------------------:|----:|-----:|------|
| d57f002 | 63,199 (1.51×) | 149 | 3,063,245 | M10K traverse + **pre-serial** sink |
| **cf6842a** | **61,267 (1.46×)** | **111** | 3,063,245 | M10K traverse + **serial IQ** sink |

**Not in either map:** `h264_p_chroma_res_apply`, sink chroma ports/pred/DC path,
`chroma_qp` / `chroma_dc_hadamard_inv` product wiring, PPS `chroma_qp_index_offset`
path as a kept consumer, P residual-before-fetch chroma apply.

**Do not declare “the decoder fits” from cf6842a.** Honest line:

> *Luma-only tree at 1.46× ALMs after serial IQ; sink DSP 4≤12 PASS; chroma not included.*

Correctness at **cf6842a** (lane evidence `1c7c5305`): clip1 **300/300** y_px exact,
clip2 **1170/1170** y_px exact, RED `FAULT_SERIAL_IQ_ZERO` **0/300** discriminates —
serial IQ is **load-bearing**, not pruned. Area ALM gate remains MISS.

## 2. Measured chroma *leaves* (coord-map3b @ 1e1fbe1) — units disciplined

Entity table = **comb ALUTs**, not ALMs. Parent paraphrase “8, 249, ~690 ALMs” is
**comb ALUTs** (and for hadamard also DSP):

| Entity | Comb ALUTs | DSP | Notes |
|--------|----------:|----:|-------|
| `h264_chroma_qp` | **8** | 0 | trivial |
| `h264_chroma_dc_hadamard_inv` | **249** | **8** | leaf DSP cost |
| `h264_chroma8x8_pred` (standalone leaf) | **690** | 0 | cheap alone |
| `h264_chroma8x8_pred` **in-sink** `u_chr_pred` | **3,859** | 0 | real sink child |
| sink @ 1e1fbe1 (pre-serial + chroma) | **40,456** | **92** | vs map2d sink 40,439 / 64 |

map3b whole: **48,436 ALMs needed · 154 DSP** (different product base than cf6842a;
not directly subtractable from 61,267).

**Leaf takeaway:** chroma leaves are not a second traverse bomb. **In-sink pred ~4k
comb** is the main measured chroma fabric adder on the pre-serial sink.

## 3. Unmeasured: `h264_p_chroma_res_apply.sv` (278 lines NEW)

Quoted from pre-rebase tree (`31c5991c` / tag `chroma-pre-rebase-ad30babe`):

```systemverilog
h264_dequant4x4 u_dq (...);   // PARALLEL combo dequant — not serial
h264_idct4x4 u_idct (...);
h264_chroma_dc_hadamard_inv u_dc (...);
```

Comment claims “shared dequant/IDCT” **per block over time**, but the instance is
still **`h264_dequant4x4`** (the parallel mul farm), not `h264_dequant4x4_serial`.
map3b priced that module class at **~52 DSP** inside the pre-serial sink.

**This module is a first-class DSP risk on the merged tree** if it ships beside a
serial-IQ sink without sharing one serial unit.

## 4. Bounded ALM estimate for chroma **on top of cf6842a** (uncertainty explicit)

Base (measured, luma-only, with probe): **61,267 ALMs needed**.

| Band | Δ map ALMs (proxy) | What’s in the band | Confidence |
|------|-------------------:|--------------------|------------|
| **LOW** | **+2,000 .. +5,000** | One in-sink `chr_pred` ~4k comb + qp/dc ~0.3k comb; packing friendly; no second parallel IQ fabric | Medium — uses map3b child sizes |
| **MID** | **+5,000 .. +12,000** | + chroma neighbour linebufs/FSM self logic; P `p_chroma_res_apply` idct/state; mild duplication | Low–medium |
| **HIGH** | **+12,000 .. +25,000** | Parallel `h264_dequant4x4` fabric re-expanded outside serial share; double pred engines; RFS/export churn | Low — failure mode, not plan |

**Point estimate (not a measurement): ~+7k ALMs** if serial IQ is preserved and
chroma pred matches map3b in-sink size.

**Headroom math (device 41,910):**

```
cf6842a luma-only whole     61,267
device                       41,910
headroom before chroma     −19,357   (NEGATIVE)
+ chroma MID               +5k..12k
merged whole (probe-style)  ~66k..73k   still ~1.6–1.75×
```

**There is no positive ALM headroom on the measured tree for chroma to “fit into.”**
Chroma is an incremental tax on a tree that is already over. Product-without-probe
composition is smaller (map1 **21,645** ALMs) but still hosts the same sink
**~39k comb** entity — the ALM wall remains the sink, not the chroma leaves.

**Will not convert comb→ALM at a flattering ratio to claim a pass.**

## 5. DSP arithmetic — **merged tree** (the sharp question)

### 5.1 Measured pieces (same units: DSP blocks)

| Piece | DSP | Source |
|-------|----:|--------|
| cf6842a whole (luma probe tree) | **111** | map summary |
| of which sink serial IQ | **4** | u_dq=2 + u_had=2 |
| of which probe parallel `u_had` (not product) | **32** | entity table |
| of which stub parallel `h264_dequant4x4` | **32** | still in product decode_stub |
| of which traverse | **1** | entity |
| chroma DC hadamard leaf | **8** | map3b |
| pre-serial sink total (with chroma, map3b) | **92** | included parallel dq 52 + had 32 + chroma extras |
| parallel `h264_dequant4x4` class | **~52** | map3b u_dq / isolate related |

### 5.2 Product-intent merged scenarios (labelled estimates)

Start from map1 product **74 DSP**, add decode-path extras, retire parallel stub
dequant only when product actually instantiates serial sink instead.

**A. Good merge (serial IQ shared; no second parallel dequant):**

```
product map1                         74
− stub parallel dequant retired     −32
+ serial sink IQ                     +4
+ chroma_dc_hadamard_inv             +8
+ traverse                           +1
+ p_chroma using SAME serial dq      +0   (no new mult farm)
────────────────────────────────────────
product-intent merged DSP           ~55   << 112  CLEAR
```

**B. Sink serial + p_chroma keeps own parallel `h264_dequant4x4` (current apply RTL):**

```
… as A but
+ p_chroma parallel dequant         +52
────────────────────────────────────────
product-intent merged DSP          ~107   ≤112 by ~5  FRAGILE
```

**C. Regression: sink chroma path re-introduces parallel dq/had (pre-serial sink+chroma):**

```
product 74 − 32 + 92 (map3b sink) + 1 ≈ 135  > 112  FAIL
```

**D. Map-tree composition like cf6842a probe (keeps stub 32 + probe had 32) + chroma 8
+ optional p_chroma 52:**

```
111 + 8           = 119  > 112  FAIL even without p_chroma parallel
111 + 8 + 52      = 171  FAIL hard
```

Probe-style totals are **not** the ship number; they show how easy it is to
**look** overbooked while measuring.

### 5.3 Answer to parent

- If merge **preserves one serial dequant** and adds only chroma DC hadamard (**8 DSP**)
  + pred (**0 DSP**): merged product DSP **~55**, comfortable under 112.
- If **`h264_p_chroma_res_apply` keeps parallel `h264_dequant4x4`**: **~107 DSP**,
  clears 112 only by a few blocks — **pattern-of-the-day risk** (ALM work “done”,
  DSP fails at merge).
- **Re-serialising apply onto `h264_dequant4x4_serial` (or a shared IQ unit) should be
  a merge acceptance criterion**, not a follow-up.

cf6842a sink **4 ≤ 12** does **not** budget chroma’s **8** DC DSP or a second farm.

## 6. Divergence / rebase risk (early warning)

| Signal | Evidence |
|--------|----------|
| Two sink parents | chroma-pre-rebase sink **743 lines**, parallel `h264_dequant4x4`; cf6842a sink **615 lines**, serial IQ only |
| Chroma WIP not ancestor of cf6842a | `31c5991c` / `14054416` **not** ancestors of `cf6842a` |
| Apply architecture clash | `p_chroma_res_apply` **still instantiates parallel dequant** while sink header says never instantiate parallel dequant |
| Live worktree dirty | `rtl/chroma-intra` worktree: modified sink (~1011 lines, appears mid-merge) + **untracked** chroma RTL — rebase in progress, not a clean freeze |
| Contract | traverse published `4fcbe6a9` sink-contract-phase2 for chroma rebase |

**This will not be a mechanical rebase.** Expect conflicts on every chroma state
machine insertion point in the serial sink FSM (`ST_HAD_WAIT` / `ST_IQ_WAIT` /
pred order). If apply is merged without serialising its `u_dq`, the **buildable**
tree (DSP-clean) and the **correct** P-chroma tree can diverge.

Tell parent early: **budget an explicit “one shared serial IQ” integration step**
in the rebase, not only text conflict resolution.

## 7. Next map (reserved)

1. Wait for **clean freeze SHA**: chroma-intra **rebased on cf6842a**, both-clip
   scores + RED (serial IQ still discriminates with chroma live).
2. **One** `quartus_map` of that SHA (same probe discipline; product-intent DSP
   composition noted).
3. That number — not cf6842a alone — answers whether the **ship** tree fits.

Until then: cf6842a remains the clean measurement of **two luma problem modules**
after diet; chroma cost is the **bounded estimate above**, not a fit claim.
