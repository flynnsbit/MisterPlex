# Fabric DDR performance counters (DEVICE_BW_VERIFIED instrument)

**Owner:** w-mem  
**Branch:** `w-mem-ddr-perf-counters`  
**PLXP version:** **2** (latency histogram + efficiency)  
**Default:** OFF (`DDR_PERF_COUNTERS` undefined) — product byte-identical.  
**Fit:** none from this lane.

## Why

720p I420 @24 fps ≈ 33.2 MB/s write plus scanout reads, plus (soon) scattered MC
reads for fabric decode. Prior margins were simulation-only (`DEVICE_BW_VERIFIED=0`).
These counters measure **post-arbiter** f2sdram beats/stalls/**latency distribution**
on real silicon.

Related: `docs/ddr-bw-budget-model.md` (MODEL), `docs/ddr-decoder-arb-contract.md`.

## Enable (fit recipe)

```tcl
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "DDR_PERF_COUNTERS=1"
# Do NOT combine with FABRIC_FRAME_DMA for the full PLXP publish path:
# m2 is the perf mailbox when PERF alone; DMA owns m2 when FABRIC_FRAME_DMA=1.
```

## Resource (estimate — no fit this lane)

| Block | M10K | ALM EST |
|---|---:|---:|
| `ddr_perf_counters` | **0** | ~280–360 (bins+eff) |
| `ddr_perf_mailbox` | **0** | ~100–140 (24×64 pack) |
| arbiter3 delta | **0** | ~50–100 |

**M10K total: 0.**

## PLXP v2 layout (FPGA→ARM)

Physical base = `doorbell_phys + 0x200`.

| Doorbell | PLXP base |
|---|---|
| 480p `0x300FF000` | **`0x300FF200`** |
| 720p `0x3047F000` | **`0x3047F200`** |

**24×** 64-bit LE qwords (192 bytes):

| Word | Contents |
|---:|---|
| 0 | header `{sat[15:0], seq[7:0], ver=2[7:0], magic=0x504C5850}` **last** |
| 1 | `cycles` |
| 2 | `wr_beats` (`WE && !BUSY`) |
| 3 | `rd_beats` (`DOUT_READY`) |
| 4 | `stall_cyc` (`(RD\|WE) && BUSY`) |
| 5–7 | `lat_sum`, `lat_max`, `lat_n` (cmd→first-data) |
| 8–9 | `m0_rd`, `m0_wr` |
| 10–11 | `m1_rd`, `m1_wr` |
| 12–13 | `m2_rd`, `m2_wr` |
| 14–19 | `lat_bin0..5`: cycles **0–7, 8–15, 16–31, 32–63, 64–127, 128+** |
| 20 | `rd_cmds` |
| 21 | `burst_sum` (mean burst = burst_sum/rd_cmds) |
| 22 | `{issue_cyc[63:32], single_cmds[31:0]}` |
| 23 | trailer `{seq, magic}` |

Auto-publish ~ every 2^20 clk_ddr (~11.6 ms @90 MHz).

### Formulas

```
wr_MBps = wr_beats * 8 * clk_ddr_hz / cycles / 1e6
rd_MBps = rd_beats * 8 * clk_ddr_hz / cycles / 1e6
lat_mean = lat_sum / lat_n
mean_burst = burst_sum / rd_cmds
frag = single_cmds / rd_cmds
beat_eff = (wr_beats + rd_beats) / issue_cyc
stall_frac = stall_cyc / cycles
```

## EXACT SSH read procedure (parent runs this)

Host defaults: `MISTER_HOST=192.168.1.183`, `MISTER_PASS=1`.

```bash
# 1) Confirm core loaded with DDR_PERF_COUNTERS=1 build (parent's fit).
# 2) Wait >20 ms for at least one PLXP publish, then dump 24 qwords.

HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
# 480p product doorbell page:
BASE=0x300FF200
# 720p layout doorbell page (if that build is loaded):
# BASE=0x3047F200

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$HOST" "\
  for i in \$(seq 0 23); do \
    A=\$(( $BASE + i*8 )); \
    printf '%02d 0x%08x ' \$i \$A; \
    devmem \$A 64; \
  done"
```

### Coherent decode (seqlock)

```
repeat:
  h1 = read64(base+0)
  payload = read64(base+8 .. base+0xB0)   # words 1..22
  t  = read64(base+0xB8)                  # word 23
  h2 = read64(base+0)
until magic(h1)==PLXP && h1==h2 && ver==2 && seq(h1)==seq(t)
```

Host helper: `host/libmisterplex/ddr_perf_counters.hpp` (`kNumQwords=24`, `kVersion=2`).

### Quick awk (after paste of 24 lines `idx addr value`)

```bash
# Expect word0 low 32 = 0x504C5850, ver byte = 2
```

## Controls

| Test | Role | Expect |
|---|---|---|
| `test_ddr_perf_counters_rtl_sim.sh` pos | POS beats+bins+eff | wr=16 rd=5 bin0=1 bin2=1 |
| same, stall | NEG FAULT_MISCOUNT_STALL | stall not counted |
| same, bin | NEG FAULT_MISBIN_LAT | long lat forced bin0 |
| `test_ddr_perf_decode` | host seqlock | POS + torn/magic/ver NEG |
| `test_ddr_arbiter4_scanout_bound.sh` | m0 WC bound | POS wait≤BOUND; NEG starve |

## Default OFF justification

Always-on cost is modest (0 M10K) but adds ALMs on the DDR timing path before
first 720p STA. Keep ifdef until parent enables for a measurement fit.
