# DMA-only mode + bank serial anomaly chase (w-path)

## Parent result on e8f1710a (scratch ABI)
```
pl330_transfer ok=1 started=1 detail="chunked ok"
pl330_dma_ms_per_frame=23.839  ok_frac=1.000
serial_cpu_copy_ms_per_frame=21.107
dma_minus_serial=+2.731
```
DMA wall was **worse** than CPU copy. Two measurement taxes identified in code
(not yet device-reproven after fix):

1. **Restage every iter** — `loadStaging` is CPU memcpy into O_SYNC staging;
   was inside the DMA timer.
2. **1 KiB chunking** — 1382400/1024 = 1350 programs; each poll could
   `usleep(10)` → ≥13.5 ms sleep tax alone.

## This build
- PL330 **auto burst-16** nested LC1×LC0 for full 720p frame (one ~31 B program).
- Bench default times **pure DMA** (staging prefilled once). `--restage` opt-in.
- **`--dma-only --duration-s N`** — no serial phase; sustained DMA for parent
  decode-overlap gate.
- **`--bank-sweep`** — same O_SYNC recipe across phys targets including
  `0x30200000` (prior) vs Option-C bank1 `0x30300000`.

## PRE-REGISTER (parent device)
| # | Claim | HIT if |
|---|--------|--------|
| P1 | dma-only starts | `started=1` `ok_frac=1` `detail` contains `burst16` or `auto` |
| P2 | pure DMA wall | `pl330_dma_ms_per_frame` **&lt;** same-run serial (expect ~8–18; MISS if still &gt; serial) |
| P3 | bank anomaly | `\|delta(0x30200000 − oc_b1)\| ≤ 1.5 ms` → harness; else address real |
| P4 | sustained | `--duration-s 25` runs; parent pairs with decode probe |

## Parent commands
```bash
# From worktree after make arm-pl330-ingest-bench:
# copy build/arm/ddr_pl330_ingest_bench to device

# THE architecture gate — DMA bg + decode:
ddr_pl330_ingest_bench --dma-only --duration-s 25 --bank 1
# parallel: ffmpeg_cpu_probe 300f real720p_2600k.mp4
# Route A REAL iff decode stays under 41.667 ms/f

# Bank anomaly (serial only):
ddr_pl330_ingest_bench --bank-sweep --len 1382400 --loops 40

# Classic compare pure DMA vs serial:
ddr_pl330_ingest_bench --len 1382400 --loops 50 --bank 1
# Optional old (inflated) recipe:
ddr_pl330_ingest_bench --len 1382400 --loops 30 --bank 1 --restage
```

## Honesty
- Prior 23.8 ms is **not** pure DMA bandwidth.
- Burst-16 nested microcode is unit-encoded; device must reconfirm `ok_frac=1`
  (chunked path already did on burst-1).
- If burst-16 faults, bench falls back to chunked only when encode failed before start.
