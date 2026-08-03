# Product path: 960×540 source → 720p glass (not 720p source)

## Standing budget (parent device, corrected — cite this)

Includes **decode + sws + rawvideo out** (not `-f null` alone). Copy @ structural
88.045 MiB/s uncached bank. Deadline 41.667 ms (24 fps).

| path | decode+sws | copy | total | margin | verdict |
|--|--|--|--|--|--|
| **PMS→960×540** (product) | **26.08** | **8.42** | **34.50** | **+7.16** | **PASS** |
| PMS→1280×720, ARM↓960 | 51.78 | 8.42 | 60.20 | −18.53 | FAIL |
| PMS→1280×720, ARM↓624 | 44.95 | (before copy) | — | — | FAIL alone |
| True 1280×720 + full copy | ~35.5 | 14.97 | ~50.5 | ~−8.8 | FAIL |

**Correction:** earlier +10.49 ms used decode-only; true margin is **+7.16 ms**
(optimistic by 3.33 ms). Still shippable PASS.

**Architecture quantified:** asking PMS for the right resolution is **1.74×
cheaper** e2e than fetching 720p and downscaling on ARM. Never use “get 720 and
shrink” as a fallback.

Constants: `kPlex540pDecodeSwsMsPerFrame` / `Total` / `Margin` in `osd_menu.hpp`.

## Product statement

```
PMS  -> Constrained Baseline 960×540  (videoProfile=baseline, level 31)
ARM  -> decode + minimal sws + bank copy = 34.50 ms   margin +7.16
FABRIC -> upscale 960×540 → native 1280×720 raster on glass
```

Honest user label: **"540p source / 720p glass"**. Not true 720p source.

## Host surfaces (w-path)

| Item | Location |
|--|--|
| Policy | `ContentPresentPolicy::Source540pFabric720p` |
| Ladder | `540p` / `960x540`, `kPlex540pWeakBitrateKbps=2000` (quality default) |
| Level | `kPlex540pH264Level=31` |
| Genuine gate | `isGenuine540pDelivery(960,540)` + height negatives |
| Conf trap | `DDR_YUV_FORCE_SCALE=1` forces sws even when delivery matches — prefer identity when coded==bank (parent measured the +3.57 ms sws term) |

## Upgrade path (not blocking glass)

PL330 verified DMA kills the ~8–15 ms copy → true 1280×720 source may fit.
Still BLOCKED on channel fault diag (`PARENT_COMMANDS_PL330_FAULT_DIAG.md`).

## Other lanes

- **w-scaler:** 1.333× non-integer 960→1280 — load-bearing filter.
- **w-clock:** `clk_pix` ~29.7 MHz for 720p24 CEA — gate on glass rate.
- **Parent:** e2e cast; live PMS coded size @960×540 (geometry not assumed).
