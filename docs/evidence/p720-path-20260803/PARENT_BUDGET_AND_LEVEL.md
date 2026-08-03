# Parent budget + level correction (2026-08-03)

## Profile pin — STAND DOWN

Parent grepped the wrong field name, then corrected: **baseline is already
pinned** in the request builder (`h264Profile` / `videoProfile=baseline`).
w-path fabric-gate + hard pin (`7cc590c0`) remains useful as defense-in-depth
and High/CABAC refuse; **no further profile-pin task**.

## Level: request vs delivered

| Ladder | Requested `videoLevel` | Notes |
|--|--|--|
| 240p/480p default WeakLadder | **30** (L3.0) | shipping |
| Path720p (`kPlex720pH264Level`) | **31** (L3.1) | MaxFS for 1280×720 |

Parent measured a true-720 delivery at **level=31** even when some paths still
advertise 30 — PMS raises level because 720p is not expressible at L3.0.

**Rule for w-mem / DPB / ring consumers:** size reference buffers from the
**delivered SPS `level_idc`**, never from the request constant alone.
Host surface: `SpsInfo.level_idc` in `h264_sps.hpp` (already parsed).

## ARM decode + structural copy (parent, clean device)

Copy at measured **88.045 MiB/s** structural uncached bank. Deadline 41.667 ms.

| stream | px | decode | copy | total | margin | verdict |
|--|--|--|--|--|--|--|
| 624×480 @1800k | 299 520 | 16.23 | 4.87 | **21.09** | **+20.57** | PASS |
| 1280×720 @1500k | 921 600 | 33.64 | 14.97 | **48.62** | −6.95 | FAIL |
| 1280×720 @2600k | 921 600 | 35.47 | 14.97 | **50.44** | −8.77 | FAIL |

**True 720p source + ARM move is closed FAIL** at every measured bitrate.
480p product has ~half a frame of idle budget.

## Strategy (parent words — do not blur)

1. **720p output today:** fabric native 1280×720 raster + w-scaler upscale from
   an ARM-affordable source (e.g. 624×480). Real 720p **glass**, not 720p **source**.
2. **True 720p source:** needs frame→bank without the 15 ms CPU copy → **PL330**
   (still BLOCKED pending FTR/4 KiB diag) or fabric decode (multi-month).

DMA remains the difference between (1) and (2). Diagnose; do not force.
