# Budget attack predictions (pre-registered) — w-path 2026-08-03

Goal: can **960×540 @30** fit 33.333 ms if we attack the standing **34.50**?

Standing (parent device, product path class):
```
decode+sws+rawvideo  26.08 ms
DDR copy @88 MiB/s    8.42 ms   (777600 B structural)
TOTAL                34.50 ms   vs 33.333 → FAIL −1.17
```

## Code predictions (before grep confirmation)

| ID | Prediction |
|----|------------|
| **P-thr-code** | Daemon **does not** set `AVCodecContext.thread_count` / `-threads`. Product is CLI FFmpeg subprocess, not in-process libavcodec. |
| **P-thr-default** | FFmpeg CLI default on this host ≈ **auto** (`threads=0`) → multi-threaded h264 + filtergraph on dual-core when measured. |
| **P-fmt** | Product `PRESENT=fpga` already requests **`-pix_fmt yuv420p`** rawvideo — **no I420→RGB** on the DDR path. Colour-convert prize is **near zero** for product glass. |
| **P-sws** | Tight 960×540 + verified delivery → **identity_skip** (no scale). Residual “sws” in 26.08 is mostly decode + raw pack/pipe, not RGB convert. Forced scale adds ~3.57 ms (prior parent note). |

## Stage split predictions (device-class / host proxy)

| stage | prediction ms | notes |
|-------|-------------:|-------|
| H.264 decode (`-f null`) | **18–23** | majority of 26.08 |
| scale/convert (identity path) | **0–2** | identity_skip → ~0; forced sws → ~3.5 |
| rawvideo pack+pipe | **3–6** | 26.08 − decode |
| DDR copy | **8.42** | structural, format-independent for I420 size |
| **I420→RGB** (product fpga) | **~0** | not on path |

## Threading win predictions

| ID | Prediction |
|----|------------|
| **P-thr-1** | `-threads 1` vs default: decode-null **slower by 1.2–1.8×** on dual-core class (prior 720 path: 41→52 ms). |
| **P-thr-2** | `-threads 2` / `frame+slice` vs default: **≤15%** further win if default already auto — **not** a 2× free lunch. |
| **P-thr-30** | Even optimistic −20% on 26.08 → 20.9 + 8.42 = **29.3** → **PASS @30**. Realistic −5–10% if already threaded → **32.5–33.5** → **borderline / still FAIL**. |
| **P-thr-miss** | If default is already dual-core saturated, threading experiment **MISS** for unlocking 540@30; copy remains 8.42 floor. |

## PMS frameRate=30 Extra

| ID | Prediction |
|----|------------|
| **P-fr30** | Same Extra form with `value=30` is **accepted** (decision frameRate≤30). On 29.97 source → deliver **~30/1 or 30000/1001** (not forced down). On 24 source → stay **24** (upper bound, not force-up). |
| **P-fr30-geom** | Geometry unchanged at 960×540 / 640×360 when bitrate ≥ knee. |

## Recommendation prediction (before measure)

Colour-to-fabric is **wrong prize** for this path (already I420). Real attack surface: **decode CPU** + **DDR copy**. Threading may shave decode; copy needs WC/DMA (other lanes). If threading MISS, **540@30 stays FAIL** and fps-aware 360@30 / 540@24 stands.
