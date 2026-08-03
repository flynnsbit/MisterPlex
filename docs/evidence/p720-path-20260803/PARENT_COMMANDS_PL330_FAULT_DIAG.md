# Parent commands — PL330 channel-fault surgical diag (w-path)

**Context:** full-frame auto run returned honest `NO_REAL_DMA`:
```
saw_exec=0  csr=0x00200002  detail=burst16 ... channel fault
```
`csr` low nibble `0x2` = **cache_miss** (i-fetch), not a success. Bench did
not invent a rate. Status: **BLOCKED**, not FAILED.

**Binary:** rebuild + deploy
```bash
make -C /home/flynnsbit/Projects/MisterPlex-wt-path arm-pl330-ingest-bench
# copy build/arm/ddr_pl330_ingest_bench → device
```

**PRE-REGISTER**
```
D1: pl330_crd / mfifo_words printed (MFIFO depth)
D2: ftr_tag is one of undef_instr|operand_invalid|ch_rd_err|ch_wr_err|mfifo_err|...
D3: 4 KiB burst1 either VERIFIED content match OR same FTR family as full-frame
D4: if 4 KiB works and 1.38 MB fails → encode/burst/scale bug
D5: if 4 KiB also ch_rd_err on prog/staging PA → bus/secure/map path, not burst16
```

## Ladder (stop when the split is clear)

Device clean (`ps w` = NONE_CLEAN). Bank 1 only.

### 0 — always print CRD + fault regs (any len)
```bash
ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1
# Read: pl330_crd, mfifo_words, pl330_fault_regs ftr_tag=, csr_state=
```

### 1 — minimal transfer (separates "won't run" vs "burst16 encode")
```bash
ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1
# optional pin NS:
ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1 --force-ns 1
ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 1 --force-ns 0
```
**Accept:** `pl330_verdict=VERIFIED_REAL_DMA` + `full_match=1`  
**Or:** same `ftr_tag` as full-frame → fundamental path fault

### 2 — still small, larger burst (MFIFO / CCR)
```bash
ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 4
ddr_pl330_ingest_bench --len 4096 --loops 1 --bank 1 --burst 16
```

### 3 — medium length burst1 (loop nesting)
```bash
ddr_pl330_ingest_bench --len 65536 --loops 1 --bank 1 --burst 1
```

### 4 — full frame only after a green small step
```bash
ddr_pl330_ingest_bench --len 1382400 --loops 1 --bank 1 --burst 1
ddr_pl330_ingest_bench --dma-only --duration-s 25 --bank 1   # auto burst, gated
```

## How to read FTR (DDI0424)

| ftr_tag | Likely cause |
|--|--|
| `undef_instr` | bad microcode byte / LPEND |
| `operand_invalid` | CCR/loop illegal |
| `ch_rd_err` | src **or instruction fetch** bus error (prog @ 0x30600000?) |
| `ch_wr_err` | dst bank bus error |
| `mfifo_err` | burst > MFIFO depth (auto now caps to CRD) |
| `dbg_instr` | debug GO/KILL issue |

`csr_state=cache_miss` with fault → channel never finished i-cache fill from
`pl330_prog_pc` (usually `0x30600000`).

## Instrument changes this tip
- Dump **FSRD/FSRC/FTRD/FTR_ch/CPC/CRD/mfifo**
- `--burst N` / `--force-ns 0|1`
- Cache-miss alone no longer counts as `saw_executing`
- Auto burst capped by MFIFO words from CRD
