# Structural uncached bank ceiling (parent 2026-08-03) — **narrowed**

## Evidence
```
/proc/cmdline : mem=511M memmap=513M$511M
/proc/iomem   : System RAM only to 0x1fefffff
bank 0x30000000 / Option-C 0x30180000 — outside kernel RAM
--sync 88.045 MiB/s 14.974 ms/f
--no-sync 85.670 (slower); --no-sync --flush 66.595
```
O_SYNC knob inert on `/dev/mem`.

## Claim scope (parent + rd-duck correction)

**Accurate:** 88 MiB/s is structural for **`/dev/mem` mappings of the reserved
region**, because `!pfn_valid` → kernel `pgprot_noncached` (both O_SYNC arms).

**Retracted:** “88 MiB/s is structural and not tunable” as a universal memory
ceiling. A dedicated driver mapping `pgprot_writecombine` was never measured.
True-720 serial needs ≥ **230.2 MiB/s** (~2.615×) — demanding but falsifiable.

## Architecture (post unbind incident)
| Path | Status |
|------|--------|
| CPU memcpy via `/dev/mem` | DEAD for true 720p24 source (35.94+14.97≥50.9) |
| CPU memcpy via **WC driver map** | OPEN — Route W; pass ≥230.2 MiB/s |
| DecodeIntoBank on noncached | SUSPECT — do not productize |
| Userspace PL330 DMAGO | LAB ONLY — fights live `dma-pl330`; unbind hung SoC |
| **Kernel dmaengine client** | PRODUCT DMA route (Route K) |
| Fabric decode | multi-month; not near-term glass |

## Instrument
Raw PL330 bench remains diagnostic only. Product work: `misterplex_bank` kmod +
`misterplex_bank_kabi.hpp`. See `KERNEL_DMA_AND_WC_DESIGN.md`.

**FORBIDDEN without serial+PDU:** unbind `ffe01000.pdma` / `dma-pl330`.
