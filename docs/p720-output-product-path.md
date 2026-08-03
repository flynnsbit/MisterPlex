# 720p OUTPUT product path (parent 2026-08-03)

## What ships

```
PMS  -> Constrained Baseline 960x540  (videoProfile=baseline pinned)
ARM  -> decode + sws/out 26.08 ms + native copy 8.42 ms = 34.50 ms
       margin +7.16 ms vs 41.667 @24fps
FABRIC -> upscale 960x540 -> native 1280x720 raster on glass
```

This is **720p output**. It is **not** 720p source.

## Correction log

| Figure | Status |
|--------|--------|
| +10.49 ms margin (decode-only 22.75 + copy) | **Retracted as ship figure** |
| +7.16 ms margin (decode+sws 26.08 + copy 8.42) | **Standing product** |
| sws/out overhead | +3.57 ms (measured; conf has FORCE_SCALE) |

`-f null` is decode only. First sws probe `wall_s=0.08` was ffmpeg `-y` omission, not a result.

## Ask PMS, do not ARM-downscale

| Path | ARM non-copy | +copy | margin |
|------|-------------:|------:|-------:|
| PMS→960x540 | 26.08 | 34.50 | **+7.16 PASS** |
| PMS→720p, ARM→960 | 51.78 | 60.20 | **-18.53 FAIL** |
| PMS→720p, ARM→624 | 44.95 | (before copy) | **FAIL** |

Fetching 720p and shrinking on the ARM is strictly worse than every other option.

## ABI

- `makePlex720pOutputFrom540pSourcePlan()` — publish_bytes=777600
- Tight content layout (native_push=1): Y stride **960**, chroma **480**,
  U@**518400**, V@**648000** — **not** canvas 1280/640 (shear if mismatched)
- PLXG order: geometry (canvas+native_push) → window (960×540) → origin (x0,y0)
- `ddr720pOutputProductPathAccepts` defaults to **decode+sws 26.08**
- `ddr720pArmDownscalePathRejected` — trap guard
- `ddr720p24ShipAcceptsZeroArmPerPixel` — true source / FPGA banks (unchanged)
- DPB: delivered level 31 (present banks still 2)
- Publish barrier: `ddrPublishPayloadBarrier()` / `BankProducerOrder::markPayloadVisible`
  (real `atomic_thread_fence`; **not** `atomic_signal_fence`). Product
  `sendDdrFrame` already uses `__sync_synchronize()` after memcpy.

## Fabric DDR BW @24 (theoretical peak 720 MB/s @ clk_ddr 90 MHz × 8 B)

| Model | Traffic | MB/s | frac peak |
|-------|---------|-----:|----------:|
| Host write 960×540 | 777600×24 | 18.66 | 2.6% |
| Direct (host wr + fabric rd native; scan on-chip) | 2×18.66 | **37.32** | **5.2%** |
| Writeback (+ canvas wr + canvas scan) | +66.36 | **103.68** | **14.4%** |

Both models **fit** under 25% theoretical peak before arbiter efficiency.
**Does not prove glass** — parent measures post-fit. `clk_pix` ~29.7 MHz is
required for CEA 720p24; ship `clk_sys` 20 MHz alone does **not** cover totals.

## Dependencies

- **w-scaler**: 960×540 → 1280×720 (1.333× non-integer) load-bearing
- **w-clock**: `clk_pix` ~29.7 MHz for 720p24 CEA
- **w-path**: DMA / WriteCombineDriver = upgrade to true 720p source
