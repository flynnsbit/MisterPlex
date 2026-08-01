# B1 desync model — WRONG SIGN corrected (record)

## Shipped error (parent)

Unit text historically treated producer **640×480 = 460800** as the desync story.
460800 > 449280 ⇒ **0.975** producer frames per reader raster — **cannot** place two
full TREK counters in one bank. Captured broken frame had **TREK24 n=312 twice** ⇒
contradiction.

## Correct discriminator (from captures)

Count legible counter copies **N** in one reader raster:

```
S ≈ producerBytesFromCounterCopies(449280, N) = 449280 / N
```

| N | S (bytes) | exact I420 candidate |
|--:|----------:|----------------------|
| 1 | 449280 | 624×480 (matched) |
| 2 | **224640** | **624×240** |
| 3 | 149760 | (various) |
| 4 | **112320** | matches one live PIPE_DESYNC producer_bytes |
| ~3.9 | 115200 | **320×240** (also live PIPE_DESYNC) |

## Horizontal wrap ⇒ width ≠ 624

Reader bank width is 624. Pure vertical roll of a **624-wide** producer has **no**
horizontal component (449280 = 624×720 exactly as byte packing of planes, not
display). FLASH split L/R on glass ⇒ producer width **≠ 624** (or chroma plane
mis-align from phase walk). So N=2 + horizontal wrap is **not** explained by
624×240 alone without additional phase offset into chroma; the free N→S rule
still bounds size class.

## Live PIPE_DESYNC producer_bytes (parent log; triage = w-cpu-1)

| producer_bytes | note |
|---------------:|------|
| 115200 | 320×240 I420 exact |
| 112320 | = 449280/4 (N=4 class) |
| 86400 | 240×240 I420 exact |
| 438048 | 624×468 I420 exact |

w-cpu-1 owns trip RCA. w-geom owns: FORCE_SCALE never identity_skips unverified;
teardown asserts `totalBytes % frameBytes == 0` + phase desync when measured.

## Fix in tree

- `producerBytesFromCounterCopies` in `ffmpeg_vf.hpp`
- `test_yuv420p_chroma_480p` GREEN_DESYNC: 640 NOT N=2; N=2⇒224640
- Construction gate: all listed geometries SAFE under FORCE_SCALE
