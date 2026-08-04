# Fabric DDR performance counters (DEVICE_BW_VERIFIED instrument)

**Owner:** w-mem  
**Branch:** `w-mem-ddr-perf-counters`  
**Default:** OFF (`DDR_PERF_COUNTERS` undefined) — product byte-identical.  
**Fit:** none from this lane.

## Why

720p I420 @24 fps ≈ 33.2 MB/s write plus scanout reads. All prior margins were
simulation-only (`DEVICE_BW_VERIFIED=0`). These counters measure **post-arbiter**
f2sdram beats/stalls on real silicon so the parent can compute MB/s.

## Enable (fit recipe)

```tcl
set_global_assignment -name VERILOG_MACRO "DDR_FRAME_STORE=1"
set_global_assignment -name VERILOG_MACRO "DDR_PERF_COUNTERS=1"
# Do NOT combine with FABRIC_FRAME_DMA for the full PLXP publish path:
# m2 is the perf mailbox when PERF alone; DMA owns m2 when FABRIC_FRAME_DMA=1.
```

Requires `DDR_FRAME_STORE` (product already). Uses `ddr_bus_arbiter3` with m2 =
`ddr_perf_mailbox`.

## Resource (estimate — no fit this lane)

| Block | M10K | ALM EST | Layout |
|---|---:|---:|---|
| `ddr_perf_counters` | **0** | ~200–280 | 32b FF counters + shadows |
| `ddr_perf_mailbox` | **0** | ~80–120 | SM + 16×64 shadow pack (regs) |
| arbiter3 vs 2-master delta | **0** (MLAB fifo) | ~50–100 | already measured MLAB=0 |

**M10K total: 0.** Prefer this over BRAM snapshots (timing + budget).

## PLXP mailbox layout (FPGA→ARM)

Physical base = `doorbell_phys + 0x200` (within the 4 KiB control page).

| Doorbell | PLXP base |
|---|---|
| 480p product `0x300FF000` | **`0x300FF200`** |
| 720p `0x3047F000` | **`0x3047F200`** |
| Legacy example `0x3007F000` | `0x3007F200` |

16× 64-bit little-endian qwords:

| Word | Contents |
|---:|---|
| 0 | header `{sat[15:0], seq[7:0], ver=1[7:0], magic=0x504C5850 "PLXP"}` **written last** |
| 1 | `cycles` (free-running clk_ddr counts since clear/reset) |
| 2 | `wr_beats` — accepted write commands (`WE && !BUSY`) |
| 3 | `rd_beats` — `DOUT_READY` pulses |
| 4 | `stall_cyc` — `(RD\|WE) && BUSY` |
| 5 | `lat_sum` — sum of cmd→first-data cycles |
| 6 | `lat_max` |
| 7 | `lat_n` — number of RD transactions sampled |
| 8–9 | `m0_rd`, `m0_wr` (present/scanout) |
| 10–11 | `m1_rd`, `m1_wr` (stream) |
| 12–13 | `m2_rd`, `m2_wr` (perf mailbox / dma when owner=2) |
| 14 | `sat_flags` copy |
| 15 | trailer `{seq, magic}` |

Auto-publish ~ every 2^20 clk_ddr cycles (~11.6 ms @ 90 MHz): snap then write
payload then header (seqlock).

### Coherent host read (seqlock)

```
repeat:
  h1 = read64(base+0)
  payload = read64(base+8 .. base+0x78)
  h2 = read64(base+0)
  t  = read64(base+0x78)
until magic(h1)==PLXP && h1==h2 && seq(h1)==seq(t)
```

## EXACT SSH read procedure (parent runs this)

Host defaults: `MISTER_HOST=192.168.1.183`, `MISTER_PASS=1`.

```bash
# 1) Confirm core is Plex and DDR frame store path is live (PLXD magic).
sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@"$MISTER_HOST" \
  'devmem 0x300FF128 32'   # expect low word 0x504C5844 "PLXD" on 480p product

# 2) Wait >20 ms for at least one PLXP publish, then dump 16 qwords.
sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@"$MISTER_HOST" \
  'for o in $(seq 0 8 120); do printf "%02x " $o; devmem $((0x300FF200+o)) 64; done'

# 3) Decode (on laptop) — low 32 bits of each value word are the counters.
#    magic = word0 & 0xffffffff must be 0x504C5850
#    ver   = (word0 >> 32) & 0xff  must be 1
#    seq   = (word0 >> 40) & 0xff
#    cycles, wr, rd, stall = low32 of words 1..4
```

**720p doorbell path** (if that RBF is loaded):

```bash
sshpass -p "$MISTER_PASS" ssh -o StrictHostKeyChecking=no root@"$MISTER_HOST" \
  'for o in $(seq 0 8 120); do devmem $((0x3047F200+o)) 64; done'
```

### Bandwidth arithmetic (parent)

At clk_ddr = 90e6:

```
wr_MBps = wr_beats * 8 * 90e6 / cycles / 1e6
rd_MBps = rd_beats * 8 * 90e6 / cycles / 1e6
stall_frac = stall_cyc / cycles
avg_lat_cyc = lat_sum / lat_n   # if lat_n>0
```

Idle present-only should show scanout `m0_rd` dominant. Contended 720p publish
should lift `wr_beats` and `stall_cyc`.

If `devmem` is missing on the box: `busybox devmem` or  
`dd if=/dev/mem bs=8 count=16 skip=$((0x300FF200/8)) status=none | hexdump -C`.

## Controls

| Test | Expect | true rc |
|---|---|---|
| `tests/unit/test_ddr_perf_counters_rtl_sim.sh` FAULT=0 | POS wr=16 rd=4 stall≥7 | 0 |
| same FAULT=1 | NEG stall miscount REPRO_OK | 0 |

## Default-OFF justification

Always-on would burn ~300 ALM on the razor-thin 720p STA path for a lab meter.
Macro keeps product unchanged; parent enables on the measurement fit only.
