# Distribution + threads — results (deadline statistic challenge)

Pre-reg: `DIST_THREADS_PREDICTIONS_20260803.md`.  
Logs: `probe_run/dist_threads_measure.txt`, `probe_run/dist_job_variance.txt`.

## Epistemics first (rule 0)

| claim | status |
|-------|--------|
| Device p50/p95/p99/max of the **34.50** path | **UNKNOWN** — parent published a **mean** only; box is down |
| Host per-frame inter-arrival on rawvideo | **Measured** but **not** device cost (host mean ~0.21 ms vs device 34.50) |
| Host full-job mean variance | **Measured** |
| Whether product default uses both A9 cores | **Measured** (child CPU% of 1c) |
| Whether `-threads 2` beats default | **Measured** (no) |

Mapping host p99/mean ≈ 2.2 onto 34.50 → “p99≈75 ms” is **invalid** (noise-dominated host baseline). Not used as a finding.

---

## 1) Distribution — what we can and cannot say

### Device `:3219` per-frame distribution
**Unknown.** No device capture this segment. A mean of 34.50 without p99 cannot ground a hard FAIL or PASS at the −0.25 ms scale.

### Host full-job means (12 runs, portable relative scatter)

| path | n | wall ms/f mean | sd | CV | 95% CI ± |
|------|--:|---------------:|---:|---:|---------:|
| null default (decode) | 12 | 0.2525 | 0.0115 | **4.56%** | 0.0065 |
| null `-threads 1` | 12 | 0.5247 | 0.0137 | — | — |
| raw scale+pad default | 12 | 25.11 | 0.13 | 0.50% | 0.07 |
| raw `-threads 2` | 8 | 25.17 | 0.04 | — | — |

If the **device** FFmpeg bucket 26.08 had the same **relative** CV as host null (4.56%):
- sd ≈ **1.19 ms**
- single-run mean is compatible with a wide band around 26.08
- **−0.25 ms (0.74% of 33.58) is smaller than that CV** → treating “33.58 vs 33.333” as a settled FAIL is **not justified** on one mean alone

**Verdict language change:**  
- **Not claimed:** “540@30 hard-FAIL by 0.25 ms after scale delete.”  
- **Claimed:** “Single published mean sits ~1.17 ms over 33.333 before scale delete; after ~0.9 ms scale delete the residual −0.25 is **within plausible measurement scatter** — **UNSCORED** until device p50/p99 or repeated device means.”  
- **Still claimed:** dual tier **360@30** is the **honest comfortable** 30 fps ship path on existing device-class totals (~18 ms).

### Host per-frame inter-arrival (raw scale path, 8 runs)
mean≈0.21 ms, mean(p99−mean)≈**0.25 ms**, p99/mean≈2.2 — **P-p99 HIT on host noise process**, not on device decode cost. Slowest indices **do not** cleanly lock to I-frame list `{0,50,…,350}` every run (scheduling noise).

**P-idr:** **UNSCORED** on device; proxy has 7 I / 352 P (GOP 50).

---

## 2) Buffering / pipe slack

| fact | evidence |
|------|----------|
| Product raw pipe request | `rawVideoPipeBytes_ = 2 << 20` (`media_player.hpp:392`) |
| Applied via | `applyRawVideoPipeSize` after `pipe()` (`media_player.cpp:3365–3372`) |
| Frames of 777600 B | **2.70 frames** |
| Kernel default alone | 64 KiB ≈ **0.08** frames @540 — product enlarges |

**P-pipe:** partial hit — not 64k only; **~2.7 frames** of slack. Absorbs short decode spikes (e.g. single IDR) if steady-state mean is under budget; **cannot** save a sustained mean above the deadline.

---

## 3) Threads (2)

| mode | null wall ratio vs default | pct of 1 core |
|------|---------------------------:|--------------:|
| **default (no `-threads`)** | 1.00 | **~348%** |
| `-threads 0` | ≈ default | multi |
| `-threads 1` | **2.08× worse** | ~118% |
| `-threads 2` | raw wall ≈ default (1.00×) | multi but **no win** |

**P-thr-now: HIT** — already both cores.  
**P-thr-help: HIT** — explicit t2 does not beat default.  
**P-thr-pipe: HIT** — threading is a decode lever; pipe/copy 8.42 untouched.  
**Do not wire `-threads 2` expecting a 0.8% miracle.**

Parent pre-reg (“threads help decode not pipe”): **HIT** on the second half; first half N/A because decode already multi.

---

## 4) Request-path guards (parent ask)

Landed this commit:

1. **`validateWeakLadder` hard floor**  
   - 540p: `maxVideoBitrate >= 2000` (`kPmsTrue540pMinBitrateKbpsMeasured`)  
   - 360p: `maxVideoBitrate >= 1000`  
   - NEG unit: 540@1500 / 360@750 **fail validate** (`test_resolve` OK).  
   - 480p stays soft (historical ladder-drop incident).

2. **Loud banner fails** (already had `ERROR DELIVERY_MISMATCH`; added named tags):  
   - `ERROR GENUINE_540_FAIL` when decode tier 960×540 and `!isGenuine540pDelivery` (covers **720×404**)  
   - `ERROR GENUINE_360_FAIL` similarly for 640×360 tier  

---

## 5) (3) pix_fmt — queued one-liner (code, not full task)

Product FPGA path: `wantYuvDdr` → **`yuv420p`** (`media_player.cpp:3189–3192`). Not rgb24 on present. Full convert-cost prize remains ~0 (prior).

---

## Plain statement for parent

I will **not** abandon 540@30 on a −0.25 ms mean residual, and I will **not** claim it PASSes.  
**Status: UNSCORED @30 on mean-after-scale-delete** until device distribution or multi-run device means exist.  
**Honest ship @30 today: 640×360.**  
**540 remains the detail tier @24** (Extra fr24) where +7.16 on the published mean still has margin even under modest CV.

`ddrFrameGeometryForFpgaPresent` untouched.
