# Bresenham V_TOTAL source-lock (rd-duck) — design + honesty fence

## Why cadence / fps_1001 alone cannot close B15

`present_core.sv` (quoted):

```
// NOTE: DDR bank swap uses vsync_pulse=fstart && swap_pending — NOT advance.
```

`present_cadence.advance_unique` only moves telemetry / content_index math.
**Physical bank swap** is `fstart && swap_pending` (ARM-owned pending).

Therefore:

| Path | Affects glass unique frames? |
|------|------------------------------|
| q5 `content_fps` / film class → fixed V 705/564 | beam **period** only |
| `present_cadence` advance | counters; **not** DDR swap |
| ARM `swap_pending` at publish | **yes** — unique bank changes |
| Fractional / Bresenham beam V_TOTAL | beam period → when fstart fires vs wall clock |

If ARM paces banks at 23.976 while beam is fixed 24.000672, the same bank is
**naturally repeated** ~every 40.57 s even if cadence counters look “right”.
**Do not close B15 on a wire flag or cadence counter.**

## Fixed-integer beam residual (H_TOTAL=1182, clk=20e6)

| Target | Fixed V | Beam Hz | ΔHz | Slip |
|--------|--------:|--------:|----:|------|
| 24000/1001 | 705 | 24.000672 | +0.024648 | ~40.57 s |
| 30000/1001 | 564 | 30.000840 | +0.030810 | ~32.46 s |
| **exact 24** | 705 | 24.000672 | +0.000672 | **~24.80 min** |
| **exact 30** | 564 | 30.000840 | +0.000840 | **~19.84 min** |

Integer class selection is not free of long-haul slip either.

## Cheap nominal fix: Bresenham V_TOTAL @ H=1182

Mean cycles/frame = `clk/rate`. Mean V = `clk/(rate·H)`.

| Rate | Mean V (exact rational) | 2-value pair | Duty on higher V |
|------|-------------------------|--------------|------------------|
| 24000/1001 | **1251250/1773** = 705.7247602933 | 705/706 | 0.7247602933 |
| 30000/1001 | **1001000/1773** = 564.5798082346 | 564/565 | 0.5798082346 |
| 24 exact | **1250000/1773** = 705.0197405527 | 705/706 | 0.0197405527 |
| 30 exact | **1000000/1773** = 564.0157924422 | 564/565 | 0.0157924422 |

Verified (awk): `clk/(H·Vavg)` hits each target **exactly** (err 0 within double).
One-line jitter = H/clk = **59.1 µs**.

### Bresenham sketch (not product-wired yet)

```
// each frame_start / v_wrap:
// err += num;  // e.g. film: step toward 1251250/1773 over den frames
// if err >= den: V = Vhi; err -= den; else V = Vlo;
// Prefer classic: accumulate (target_num) mod den with Vlo base + carry → Vhi
```

Exact long-run: over 1773 frames, line-count totals match the rational mean V.

## Ascal one-line jitter

Already evidenced (default product): framebuffer scaler, OSWEEP free-runs on HDMI
`o_htotal/o_vtotal`, triple-buffer when `lowlat=0`, `vrr_mode=0`.
See `ASCAL_VSYNC_DITHER_ABSORB.md` + `test_ascal_vsync_dither_absorb.sh`.

**Scoped claim:** one-line input V jitter is absorbed on the **HDMI output raster**
under those defaults. Not proven: glass capture, lowlat=1, vrr=1, or long-haul
bank uniqueness under ARM fill.

## What would constitute source-lock CLOSE

All of:

1. Beam mean period matches content rational (Bresenham V or equivalent), **and**
2. Unique banks change under a **proven** policy:
   - either swap still ARM-paced but beam no longer outruns content, **or**
   - fabric gates `swap_pending` with a queue model that is tested, **and**
3. Long-window unique-bank count (not just `advance_unique` or `frame_start`), **and**
4. Parent ABI if NTSC flag/num-den is required to *select* the dither mode
   (bit34 still RESERVED per arbitration #4).

Until then: B15 = integer class + honest wall only.

## Priority

Parent: cadence exactness is rank **(c)** after fit + 720p present.
This doc + gate are honesty/artefact; **Bresenham FSM not product-enabled**.
