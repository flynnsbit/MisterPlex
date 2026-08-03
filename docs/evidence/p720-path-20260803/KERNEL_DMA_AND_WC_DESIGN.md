# Kernel DMA owner + write-combine bank map (w-path)

**Date:** 2026-08-03  
**Trigger:** Parent unbind of `dma-pl330` hard-hung the MiSTer (no OOB recovery).  
**rd-duck:** `/dev/mem` always `pgprot_noncached` for `!pfn_valid`; WC never exercised.

## Standing product (unchanged)

```
PMS 960×540 baseline → ARM decode+sws+copy 34.50 ms (+7.16) → fabric → 720p glass
```

True **720p source** still wants either:

- kill the ~15 ms CPU copy via **KernelDma**, or  
- speed the copy via **CpuWriteCombine** to ≥ **230.2 MiB/s**.

## What we stop doing

| Practice | Status |
|----------|--------|
| Userspace PL330 `DMAGO` / register poke | **LAB ONLY** — ownership fight proven |
| `echo … > unbind` on `ffe01000.pdma` | **FORBIDDEN** without serial+PDU |
| Claiming 88 MiB/s is universal structural | **RETRACTED** — `/dev/mem` only |

NS-CCR / FTR0 bench work remains valid **diagnostics** of the bare metal block;
it is not the ship path.

## Route K — KernelDma (`misterplex_bank`)

**Owner:** small GPL module `arm/kmod/misterplex_bank/`.

```
userspace misterplexd
    │  open /dev/misterplex_bank
    │  ioctl MPB_IOC_DMA_MEMCPY {src_phys|later dma-buf, bank, len, SYNC}
    ▼
misterplex_bank.ko
    │  dma_request_channel(DMA_MEMCPY)  → existing dma-pl330
    │  dmaengine_prep_dma_memcpy(dst_bank_phys, src, len)
    │  submit + dma_sync_wait
    ▼
reserved banks 0x30000000 / 0x30180000
    │
userspace: ddrIngestPayloadVisibilityBarrier(); doorbell
```

**Why this survives the incident:** module is a **client** of `dma-pl330`, never
tears it down. Channel allocation goes through the kernel owner.

**Open implementation items (when device is back):**

1. Replace lab `src_phys` with `dma_map_single` / pinned userspace pages or dmabuf.
2. Content-verify every transfer (no rate without match — 136 GB/s lesson).
3. Measure sustained MiB/s with decode concurrent (Route A overlap).
4. Wire `DdrIngestMode::KernelDma` in daemon when `/dev/misterplex_bank` present.

**Pass:** verified memcpy ≥ decode-overlap budget; doorbell after barrier only.

## Route W — CpuWriteCombine

**Mechanism:** `mmap` bank with `pgprot_writecombine` (module `SET_MAP_PROT` +
`remap_pfn_range`). Userspace `memcpy` into WC mapping.

**Falsify bar (parent):** ≥ **230.2 MiB/s** (~2.615× the 88.045 /dev/mem rate)
so `35.94 + copy_ms ≤ 41.667`.

**Control arm:** same module, `map_prot=noncached`, must reproduce ~88 MiB/s class
so the instrument is trusted.

**Flush policy:** WC does not need full cache clean like cached; still run
`ddrIngestPayloadVisibilityBarrier()` (`__sync_synchronize` / DMB) before doorbell
so stores are ordered relative to the SPI doorbell write.

## Host contract changes (this commit)

- `DdrIngestMode::{KernelDma,CpuWriteCombine}`; raw PL330 renamed lab.
- `begin()` **AwaitBankCredit** no longer overwritten by `Failed`.
- `atomic_signal_fence` → `ddrIngestPayloadVisibilityBarrier()` (`__sync_synchronize`).
- ABI: `host/libmisterplex/misterplex_bank_kabi.hpp`
- Skeleton module: `arm/kmod/misterplex_bank/`

## Parent commands (when device returns — no unbind)

```bash
# After module build/insmod on device:
ls -l /dev/misterplex_bank
# INFO ioctl + WC bench will land in a follow-up userspace tool.
# Until then: do NOT unbind pdma; do NOT re-run raw DMAGO as product evidence.
```

## Coordination

- **w-mem:** bank phys / size must match module defaults or become DT/params.
- **w-scaler / w-clock:** unaffected; 540→720 glass remains ship path.
- **rd-duck:** thanks for pfn_valid / fence / credit-phase catches — encoded here.
