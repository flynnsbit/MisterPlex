# Parent commands — Route W first (write-combine), then KernelDma

**Priority (w-path judgement):** WC ≥ Kernel DMA ≫ raw PL330.

## Honest cost call

| Route | Worth it? | Why |
|-------|-----------|-----|
| **W WC map** | **YES — do first** | Same thin module; mmap only; if ≥230.2 MiB/s true 720 source needs **no DMA**. Falsifiable in one bench. |
| **K dmaengine** | **Conditional** | Worth a thin client *if WC fails*. Full dmabuf/zero-copy pipeline is **not** worth multi-week investment while 540→720 glass ships. Matching MiSTer kernel headers + SD deploy is the real cost. |
| Raw PL330 / unbind | **NO** | Ownership fight + unbind hard-hung SoC. Closed. |

## When device is back (power cycle)

### 1) Never
```bash
# FORBIDDEN without serial + remote power
# echo -n ffe01000.pdma > /sys/bus/amba/drivers/dma-pl330/unbind
```

### 2) Build module (on a host with matching MiSTer kernel tree)
```bash
cd arm/kmod/misterplex_bank
make KDIR=/path/to/mister/linux
# scp misterplex_bank.ko to device
```

### 3) Load + WC bench (product prize)
```bash
insmod misterplex_bank.ko
ls -l /dev/misterplex_bank
# ARM binary: build/arm/misterplex_bank_wc_bench  (make arm-misterplex-bank-wc-bench)

# Control — must look like ~88 MiB/s class
./misterplex_bank_wc_bench --bank 1 --loops 64 --prot nc

# Candidate — pass bar ≥230.2 MiB/s + content_match=1
./misterplex_bank_wc_bench --bank 1 --loops 64 --prot wc
```

Paste `wc_rate_mibps`, `ms_per_frame`, `content_match`, `wc_verdict`.

### 4) Only if WC fails bar — KernelDma ioctl (module already loaded)
```bash
# Follow-up: DMA memcpy ioctl + content verify (tool TBD if WC fails).
# Do not start raw ddr_pl330_ingest_bench as product evidence.
```

## Lab PL330 (optional, non-product)
Default **no channel KILL** (rd-duck). Only with explicit flag:
```bash
./ddr_pl330_ingest_bench --len 4096 --burst 1 --bank 1   # kill=0 default
# ./ddr_pl330_ingest_bench ... --allow-channel-kill       # LAB ONLY
```
