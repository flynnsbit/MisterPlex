# Overlay cost @ 84.5% busy + MiSTer spin pointer

**Priority experiment:** `SOAK_AB_MISTER_QUIESCE_PGE50.md` (trimmed `p_ge50_steady`).  
**Parent load lock:** SYSTEM_BUSY **169/200**, Main **90.6**, ffmpeg **69.6**, daemon **25.6**.  
**Void on c5382bee:** PLXD frames_done/presents/drops. `unaccounted`≡`residual` (double print).  
**Question:** late ARM vs late observation — CPU is the pivot.

## Scanout constraint

`present_core.sv`: `V_STORE=240`, scale-2 store fetch → vertical glyph scale **≥2** or odd rows lost.

## Host bench (NOT silicon)

| geom | renderYuv420p µs | frac 41.67 ms |
|---|---:|---:|
| 624×480 panel 594×96 | 470 | 1.1% |
| scale≥2 ~594×192 (proj ×2) | ~940 | ~2.3% |
| 1920×1080 panel 1824×216 | 3045 | 7.3% |

A9 absolute: **UNKNOWN** — `PRESENT_PROFILE=1` only.

## Affordability @ Main 90.6 / busy 84.5%

| Work | Assessment |
|---|---|
| No chrome | OK (0) |
| Burst dirty-rect scale≥2 @624 | **Risky** — can push present tail over 41.7 ms while publisher already late-or-observed-late |
| Full-frame every-frame native-raster @800×600 / 640×480 | **Hostile** — trades judder for chrome; **do not ship** before Main A/B + profile gates |
| After MAIN_NOT_CAUSAL | Overlay still costs daemon %; gate present_us |
| After MAIN_LOAD_CAUSAL + reclaim | Overlay becomes plausible |

**Rule:** An overlay fix that starves the publisher trades one user-visible bug for another.

## Gates before shipping hi-res overlay

1. Main A/B scored on **trimmed** metrics (or reclaim landed).  
2. `PRESENT_PROFILE=1`, force chrome ≥30 calls → `MEASURED_COST`.  
3. `present_us_p99 < 35000`, `present_us_max < 41667`.  
4. `p_ge50_steady` Δ ≤ 0.03 vs no-chrome baseline.  
5. Never PLXD presents/drops/frames_done on c5382bee.

## T7 rows 240→480 (cross-ref)

ARM already writes 449280 B. FPGA Y-fetch ~2×. ARM CPU ~0 direct. Bus contention = measure trimmed + write_us post-RBF.

## MiSTer spin

Source: `poll(...,0)` CPU1. Device: strace E1. Patch lab: `patches/main_mister_input_timeout5_plex.patch`.
