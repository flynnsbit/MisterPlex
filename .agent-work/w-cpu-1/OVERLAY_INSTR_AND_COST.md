# Overlay instrumentation + cost bound (scale >= 2)

**Evidence frame:** parent overlay_lowres_evidence.png — STOPPED chrome mush.
**Mechanism:** present_core.sv STORE_Y_SCALE=2 fetches even rows only; scale=1 7-row glyphs lose odd rows -> character corruption (8->0, 6->C).
**Floor:** vertical scale >= 2 + even-parity y-origin snap. Phase is ARM-controlled; resolution cap is 240 store lines.

## Instrument (tip media_player.cpp, PRESENT_PROFILE=1)

| field | meaning |
|-------|---------|
| overlay_calls | dirty non-empty -> render attempted |
| overlay_dirty_empty | dirty empty -> never called |
| overlay_us_avg_call / overlay_cpu_us_avg_call | per-attempt mean |
| overlay_us_max / overlay_cpu_us_max | attempt tail |
| overlay_verdict | NEVER_CALLED | MEASURED_FREE | MEASURED_COST |
| present_us_p50/p95/p99/max | whole present wall distribution |

Zero decode:
- NEVER_CALLED -> not a cost measurement
- MEASURED_FREE -> called, ~0 CPU (shipping YUV break)
- MEASURED_COST -> real work (expected after renderYuv420p)

Do not gate on drops or av_drift_ms.
Use present tails + ledger frameIndex - presentCount_ - droppedFrames_ (w-geom).

## Baseline unconditional work (every YUV frame)

| call | bytes / work |
|------|----------------|
| inspectYuv420pChroma via repairDeadYuv420pChroma | walk all U+V = 149760 B every frame |
| clearYuv420pCropPadding | crop strips only (480p crop_right=6) — not full 449280 unless crops huge |
| DDR publish | full 449280 bank |

Parent "walk all 449280" is the DDR/frame bill; chroma inspect is 149760. Overlay compared to both.

## Cost bound (host bench + scale>=2 re-derive)

Host @624, hires renderYuv420p, scale1 panel 594x96 (overlay_bench_624.txt):
- YUV overlay ~476 us vs inspect ~37 us -> ~13x inspect
- A9 us = UNKNOWN (no host->A9 scale)

scale>=2 / ~2x rows (parent): panel ~594x192 ~= 38% frame px

| | host proj (linear fill) |
|--|------------------------:|
| YUV overlay | ~950 us |
| vs inspect | ~26x |
| vs 41.7 ms budget (host only) | ~2.3% |

Text at scale=2 is 4x glyph pixels; panel fill ~2x if height doubles. Silicon truth = overlay_us_max after force-chrome.

### Affordability (honest)

- Overlay is not rounding error vs chroma inspect (~13-26x on host).
- It is burst-only (kVisibleMs=3000) and dirty-rect, not always-on.
- Whether it fits 41.7 ms on A9: measure p99/max — do not extrapolate.

### Gates for hires (parent)

1. No chrome -> NEVER_CALLED
2. Force pause chrome -> MEASURED_COST, calls>=30
3. present_us_p99 < 35000, present_us_max < 41667
4. Ledger loss not worse than baseline (not drops)

## Main timeout lab

See MISTER_TIMEOUT5_LAB.md — experiment only, not product.
