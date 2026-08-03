# Parent commands — PL330 FTR0 + NS CCR (w-path)

## Context

Burst ladder (1–16 @ 4 KiB) all faulted identically:

- `ftrd=0` manager clean; `fsrc` ch0; `cpc=scratch+6` (start of **DMAMOV CCR**)
- Burst width ruled out; microcode fetch from `0x30600000` works
- Prior bench printed **FTRD** (manager) not **FTR0** (channel) → `ftr_other` was uninformative

## Fix in this binary

1. **CCR AxPROT NonSecure** (`src_prot[10:8]=2`, `dst_prot[24:22]=2`) when channel is NS (`CNS=1`). Secure default prot on NS channel is a top suspect for fault at DMAMOV CCR.
2. Bench dumps **raw FTR0**, bit string (`OPERAND_INVALID`, `CH_RDWR_ERR`, …), full program disasm with offsets, `cpc_off`, and `pl330_ccr=`.

Deploy ARM binary from this worktree:

```text
build/arm/ddr_pl330_ingest_bench
```

## Run (device clean; bank 1)

```bash
# Primary: 4 KiB burst-1 with NS CCR (default force_ns try includes ns=1)
./ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1

# Explicit NS channel GO
./ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1 --force-ns 1

# Contrast: secure CCR + secure GO (expect still fault if CNS fixed NS)
./ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1 --force-ns 0
```

## What to paste back

```text
pl330_ccr=0x...
pl330_prog_disasm ...
pl330_prog_byte_at_plus6=0xbc
pl330_fault_regs ... FTR0=0x... ftr_bits=... cns=...
pl330_cpc=... cpc_off=...
pl330_transfer ... detail=...
pl330_verdict=...
```

## Expected if NS CCR was the bug

- `pl330_transfer ok=1` / content match / **VERIFIED** (or at least not channel_fault)
- `FTR0=0x00000000` after clean stop

## Expected if still blocked

- **Raw FTR0** names cause (e.g. `OPERAND_INVALID=bit1`, `CH_RDWR_ERR=bit5`)
- Program listing proves insn at +6 is `DMAMOV_CCR` with the printed `pl330_ccr`

Do **not** force a rate on `NO_REAL_DMA`. Product path remains 960×540 → fabric 720 glass; DMA is true-720-source upgrade only.
