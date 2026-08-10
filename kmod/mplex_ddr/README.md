# mplex_ddr — write-combine DDR frame banks for MiSTerPlex

Product STREAM=0 path feeds FPGA frame-store banks at `0x30000000` (dual bank,
stride `0x180000`, doorbell `0x302FF000`). Mapping that window through
`/dev/mem` + `O_SYNC` tops out ~55–90 MiB/s on the dual-A9 (~15–25 ms/frame at
720p YUV420). This module exposes the same physical window as
`/dev/mplex_ddr` with `pgprot_writecombine`, which measures **~400–670 MiB/s**
(~2 ms/frame) on production hardware.

## Device

| Item | Value |
|------|--------|
| Node | `/dev/mplex_ddr` (0666) |
| Phys | `0x30000000` |
| Size | `0x400000` (4 MiB — banks + doorbell + bitstream ring/CTRL @ `0x30300000`) |
| Map | `mmap` offset 0, `PROT_READ|PROT_WRITE`, `MAP_SHARED` |

`misterplexd` opens `/dev/mplex_ddr` first in `ensureDdrMap()` and falls back
to `/dev/mem` when the module is absent.

## Build (host cross, MiSTer 5.15.1)

```bash
# kernel tree (once)
git clone --depth 1 -b socfpga-5.15 \
  https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git \
  /data/misterplex/kernel/Linux-Kernel_MiSTer

# match running device
ssh root@mister 'zcat /proc/config.gz' > /tmp/mister.config
# LOCALVERSION=-MiSTer ; CONFIG_MODVERSIONS is usually n

make -C "$KDIR" ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- \
  olddefconfig modules_prepare   # needs `bc` on PATH

make -C kmod/mplex_ddr \
  KDIR=/data/misterplex/kernel/Linux-Kernel_MiSTer \
  CROSS_COMPILE=arm-none-linux-gnueabihf-
```

Install on device:

```bash
scp kmod/mplex_ddr/mplex_ddr.ko root@mister:/media/fat/misterplex/kmod/
# user-startup:
insmod /media/fat/misterplex/kmod/mplex_ddr.ko 2>/dev/null || true
```

## Bench gate

```bash
# on device
ddr_write_bench --dev /dev/mplex_ddr   # expect ≥230 MiB/s, frame_ms ≤6
ddr_write_bench --dev /dev/mem         # baseline O_SYNC
```

## Notes

- Userspace PL330 DMA poke is **banned**; this WC chardev is the product KernelDma/WC step.
- Do not treat fabric STREAM=1 consumer progress as the cast ship bar — product glass is STREAM=0 + WC + host decode.
