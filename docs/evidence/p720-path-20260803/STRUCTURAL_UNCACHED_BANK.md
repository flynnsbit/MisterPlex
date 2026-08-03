# Structural uncached bank ceiling (parent 2026-08-03)

## Evidence
```
/proc/cmdline : mem=511M memmap=513M$511M
/proc/iomem   : System RAM only to 0x1fefffff
bank 0x30000000 / Option-C 0x30180000 — outside kernel RAM
--sync 88.045 MiB/s 14.974 ms/f
--no-sync 85.670 (slower); --no-sync --flush 66.595
```
O_SYNC knob inert. 88 MiB/s is structural for **CPU stores** into the bank.

## Architecture
| Path | Status |
|------|--------|
| CPU memcpy bank | DEAD for 720p24 (35.94+14.97≥50.9 > 41.667) |
| DecodeIntoBank | SUSPECT — same uncached stores+ref reloads; do not productize |
| PL330 DMA | CRITICAL PATH for any ARM 720p24; bench must content-verify |
| Fabric decode | endgame / mandate |

## Instrument
`c4cf0392`+ : Linux DMAGO, saw_executing, content match, 3.2 GB/s ceiling.
```bash
ddr_pl330_ingest_bench --dma-only --duration-s 25 --bank 1
# only VERIFIED_REAL_DMA may pair with decode probe
```
