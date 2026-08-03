# Zero-CPU-copy / overlapped bank ingest (w-path Route A)

## Why
Parent (in-session 2026-08-03): product tier decode @2600k = **36.27 ms/f**
(margin 5.40 ms). Serial + bank copy `36.27 + 15.283 = 51.55` **FAIL** (−9.88).
Overlap max sketch = 36.27 **PASS** if concurrency holds — unproven until PL330 bench.
Fabric owns pixels long-term; Route A is the bridge if DMA overlaps decode.

## Landed code (default-safe)
| Path | Role |
|------|------|
| `host/libmisterplex/ddr_zero_copy_ingest.hpp` | Session SM: credit → move → visible → doorbell |
| `host/libmisterplex/pl330_mem2mem.hpp` | PL330 NS probe + program encode + transfer attempt |
| `fpga/.../host_bank_ingest_credit.sv` | Fabric scoreboard (not in QSF; lint-only) |
| `tools/ddr_pl330_ingest_bench.cpp` | Parent device bench |
| `tests/unit/test_ddr_zero_copy_ingest.cpp` | Red/green contract |

Product path still `CpuSerial` via `sendDdrFrame` until parent greens PL330.

## Contract with w-mem
- Bank phys/stride/doorbell = `ddr_frame_layout` / Option-C (w-mem).
- `fabric_ddr_writer` = fabric producer (`publish_bytes=0` ship).
- This lane = **HPS producer** for real decode output.
- Ordering: **payload visible before doorbell** (absolute).
- PLXD credit when live: `require_bank_credit`.

## Pre-registered device predictions
1. Serial bank copy @1382400 ≈ **15.28 ms/f**
2. PL330: `probe` shows hw **or** clean fail; full-frame xfer may report `needs_prog_scratch_phys` until scratch reserved in memmap window
3. `copy_under_burn` inflate_ms ≈ 0 if bus free; **>>0** means max(decode,copy) is fictional

## Parent measure commands
```bash
# cross-built static
make arm-pl330-ingest-bench
# on device (parent copies bin):
/media/fat/misterplex/bin/ddr_pl330_ingest_bench --len 1382400 --loops 50 --bank 1
/media/fat/misterplex/bin/ddr_pl330_ingest_bench --len 1382400 --loops 30 --bank 1 \
  --overlap-burn-ms 37
```
Capture true rc directly. Does **not** ring doorbell.

## Honest gaps
- Full-frame PL330 needs physically contiguous src + program scratch in reserved DDR.
- Linux may own DMAC channels — fail must be clean (no thrash).
- Contended DDR can erase Route A margin — measure, do not assume.
- Ship gate remains fabric `publish_bytes=0` (w-mem), not PL330.
