# q5 rate-family ambiguity (rd-duck on 15a371b4)

## Spec gap

| Wire | Exact 24 | 24000/1001 | Exact 30 | 30000/1001 |
|------|----------|------------|----------|------------|
| q5 `content_fps` uint8 | **24** | **24** | **30** | **30** |

w-path `plxg_q5_aspect_cadence.hpp` buckets NTSC and integer to the same uint8.
`present_vtotal_bresenham` product **unconditionally** uses NTSC duties.

## Consequence (product NTSC beam)

| Source | Beam Hz | Δ | Producer gain |
|--------|--------:|--:|---------------|
| exact 24 | 23.976024 | 0.023976 | **~41.7 s / frame** |
| exact 30 | 29.970030 | 0.029970 | **~33.4 s / frame** |

No implementation can be exact for **both** families under current q5.

## Resolution (not this commit)

1. Awarded rational-family bit (`fps_1001`) — freeze #4 **single-window** 5-site merge, or
2. Source-clocked ARM publication/swap (beam class secondary).

**Not a fix:** more arithmetic tests, unilateral bit34, or claiming dual exact.

## Product policy

- Default Bresenham = **NTSC** (library majority).
- `FAULT_BRES_EXACT_INT` = lab exact integer only.
- Class film↔TV: **clear `acc`**, reload `vlo` (no retained phase).

## Fence

`tests/unit/test_q5_rate_family_ambiguity_fence.sh` + wall `q5_rate_family_ambiguity`.
