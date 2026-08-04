# misterplex_bank — kernel owner for frame banks

## Why this exists

Parent incident 2026-08-03: unbinding live `dma-pl330` to give userspace exclusive
PL330 access **hard-hung the SoC** (no ping, black HDMI, power cycle required).
Conclusion:

- Userspace `DMAGO` / raw PL330 is **not** a product path.
- "Just unbind the kernel driver" is **not** viable.
- Correct owner: a **dmaengine client** (this module) and/or a **WC mmap** of the
  reserved banks via `memremap(..., MEMREMAP_WC)` / `pgprot_writecombine`.

rd-duck kernel evidence: `/dev/mem` uses `pgprot_noncached` when `!pfn_valid`, so
O_SYNC never reaches write-combine. Only a dedicated mapping can exercise WC.

## Product routes (both falsifiable without unbinding pdma)

| Route | Mechanism | Pass bar |
|-------|-----------|----------|
| **KernelDma** | `dma_request_chan` / memcpy capability → bank phys | sustained content-verified DMA; no CPU copy |
| **CpuWriteCombine** | mmap bank WC; userspace memcpy | ≥ **230.2 MiB/s** (parent true-720 serial need) |

Ship glass path (960×540 → fabric 720) does **not** block on this module.
This module is the upgrade to **true 720p source**.

## ABI

See `host/libmisterplex/misterplex_bank_kabi.hpp`:

- `/dev/misterplex_bank`
- `MPB_IOC_INFO`, `MPB_IOC_DMA_MEMCPY`, `MPB_IOC_SET_MAP_PROT`
- mmap offset `bank * bank_bytes` → bank window
- **Default banks = Option-C 720p**: bank0 `0x30180000`, bank1 `0x30300000`,
  stride `0x00180000` (matches `ddr_frame_layout.hpp`). Legacy `0x30000000`
  is rejected by `misterplexBankInfoSane` (ring-stomp class).

## Hard rules

1. **Never** `driver_unbind` / `echo -n ffe01000.pdma > unbind` from product or lab
   scripts without serial console + remote power. Documented fatal.
2. Do not claim DMA rates without content verify (prior 136 GB/s incident).
3. Default map prot for first bring-up may be noncached (matches /dev/mem baseline);
   WC is opt-in via `SET_MAP_PROT` then remap.
4. Doorbell remains in userspace (`fpga_spi`) **after** ioctl sync completion +
   `ddrIngestPayloadVisibilityBarrier()`.

## Build (device kernel tree — parent runs)

Skeleton only in-tree until a matching MiSTer kernel tree is wired:

```bash
# On build host with kernel headers for the running MiSTer image:
make -C /path/to/linux M=$PWD modules
```

Not part of `make unit`. Host unit tests cover the ABI header only.
