# PL330 program scratch ABI (w-path ↔ w-mem)

## Reserved window (parent-verified)
`memmap=513M$511M` → phys `0x1FF00000` .. `0x40000000`.

## Option-C banks (w-mem)
| | phys |
|--|--|
| base | `0x30180000` |
| stride | `0x180000` |
| doorbell | `0x3047F000` |
| 2-bank end | `0x30480000` |
| 3-bank end | `0x30600000` |

## PL330 ABI (w-path Route A) — starts at triple end
| | phys | size |
|--|--|--|
| region | `0x30600000` | `0x181000` |
| prog scratch | `0x30600000` | `0x1000` |
| staging (DMA src) | `0x30601000` | `0x180000` |

Lockstep: `host/libmisterplex/ddr_frame_layout.hpp` ↔
`fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh`.

Unit: `!pl330AbiOverlapsOptionCBanks`.

## Parent re-run
```bash
make arm-pl330-ingest-bench
# device:
ddr_pl330_ingest_bench --len 1382400 --loops 50 --bank 1
ddr_pl330_ingest_bench --len 1382400 --loops 30 --bank 1 --overlap-burn-ms 37
```
Expect: `pl330_transfer started=1` (not `needs_prog_scratch_phys`).
