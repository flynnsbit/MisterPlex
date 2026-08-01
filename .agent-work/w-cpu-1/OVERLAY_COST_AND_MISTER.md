# Overlay cost (scale≥2) + pointer to MiSTer patch

**Priority:** MiSTer spin first — see **`SOAK_AB_MISTER_QUIESCE_PGE50.md`** + **`MISTER_SPIN_PATCH.md`**.  
**Parent load lock (480p cast):** SYSTEM_BUSY **169/200**, Main **90.6**, ffmpeg **69.6**, daemon **25.6**, **`p_ge50=0.1450`**.  
**Do not score PLXD frames_done/presents/drops on RBF c5382bee** (bank_vsync packed).  
**Retracted:** ERROR 17/18/19; scale=1 glyphs under STORE_Y_SCALE=2.

## Scanout constraint (parent-quoted)

`present_core.sv`: `V_STORE=240`, `STORE_Y_SCALE=2.0` → only even store rows fetched.  
**Vertical glyph/block scale must be ≥2** or characters corrupt (8→0, 6→C). Not blur — information loss.

## Instrument (tip daemon)

`PRESENT_PROFILE=1` → `overlay_calls`, `overlay_dirty_empty`, `overlay_verdict`
(`NEVER_CALLED`|`MEASURED_FREE`|`MEASURED_COST`), per-call max/avg, `present_us_p50/p95/p99/max`.

**Do not use `drops` or `av_drift_ms` as overlay health** (parent correction):

- `drops` = A/V pacer skips only  
- drift blind to publish loss (`frameIndex` vs no `presentCount_` in av_clock)  
- Loss signal = ledger `frameIndex - presentCount_ - droppedFrames_` (w-geom / w-fit-1)

Gate overlay on **present_us tails + ledger**, not drops/drift.

## Cost vs unconditional YUV work

Every present (tip): `repairDeadYuv420pChroma` → full U+V inspect **149 760 B**;  
`clearYuv420pCropPadding` = crop strips only (480p right=6), not full 449 280.

Hires `renderYuv420p`: dirty panel, per-px YUV↔RGB blend.

### Geometry

| layout | panel (624 wide) | px | frac of 299520 |
|--------|------------------|-----:|---------------:|
| prior hires scale1 metrics | 594×96 | 57024 | 19.0% |
| **rows×2 (parent scale≥2)** | 594×192 | 114048 | **38.1%** |

### Host bench (scale1 hires header) — NOT silicon

`.agent-work/w-cpu-1/overlay_bench_624.txt`: YUV **476 µs** vs inspect **37 µs** (**~13×**).

**Re-derived for rows×2 (linear panel-fill assumption, HOST only):**

| | host µs (proj) | vs inspect |
|--|---------------:|-----------:|
| rows×2 YUV overlay | ~952 | **~26×** |
| frac of 41.7 ms frame (host) | ~2.3% | — |

**A9 absolute: UNKNOWN — measure.** Do not scale host→A9.

Text/icons at scale=2 are **4× glyph pixels** (2-D); panel fill ~2× rows if height doubles. Worst case between 2× and ~4× text-dominated — **silicon max via `overlay_us_max`**.

### Gates (after hires with scale≥2)

1. No chrome: `overlay_verdict=NEVER_CALLED`  
2. Forced chrome: `MEASURED_COST`, `calls≥30`  
3. `present_us_p99 < 35000`, `present_us_max < 41667`  
4. Ledger loss not worse than baseline (not `drops`)

## Affordability @ 84.5% system busy (parent 2026-08-01)

| Work | vs 41.7 ms | At current load |
|---|---|---|
| No chrome | 0 | OK |
| Dirty-rect scale≥2 @624 (host ~0.9–2 ms proj) | small on host; **A9 UNKNOWN** | **Risky** until Main reclaim or `present_us_p99` measured |
| Full-frame every-frame hi-res @800×600 | unmeasured; 1080 host panel already 7% budget | **Do not ship** before Main A/B + profile gates |
| After Main → ~0–25% if MAIN_CAUSAL | frees ~45% of machine elastic | Overlay becomes plausible; still gate p99 |

**Gates:** `PRESENT_PROFILE=1`; force chrome ≥30 calls; `present_us_p99<35000`; `p_ge50` Δ≤0.03 vs baseline; never PLXD presents on c5382bee.

## Resolution ceiling (RTL) vs ARM cost

ARM already publishes **449280 B** (624×480). Fixing `V_STORE=240→480` / full H_DE is **FPGA read-path**; ARM inelastic **~0** direct. Second-order DDR contention = measure `p_ge50` post-RBF only.

## MiSTer

A/B + PRE_REG p_ge50: **`SOAK_AB_MISTER_QUIESCE_PGE50.md`**.  
Patch: **`MISTER_SPIN_PATCH.md`** / `patches/main_mister_input_timeout5_plex.patch`.
