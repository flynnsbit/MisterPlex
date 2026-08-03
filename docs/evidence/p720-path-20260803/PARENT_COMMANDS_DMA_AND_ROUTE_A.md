# Parent commands — DMA gate + Route A falsifier (w-path)

No agent device access. Binary paths relative to worktree
`MisterPlex-wt-path` after `make arm-pl330-ingest-bench` and
`make arm-profile-tools` (or the listed targets).

Instrument tip lineage: `c4cf0392`+ (Linux DMAGO, `saw_executing`, content
match, 3.2 GB/s ceiling, usleep poll).

---

## (1) THE open question — verified PL330 vs CPU 14.97 ms + decode under DMA

### PRE-REGISTER (write before run)
```
P1: first line is either pl330_verdict=VERIFIED_REAL_DMA or NO_REAL_DMA/honest fail
    — never 98k fps / sub-0.4 ms without INSTRUMENT_FAIL rc=2
P2: if VERIFIED: pl330_dma_ms_per_frame in [0.5, 40] and throughput_GBs <= 3.2
P3: if VERIFIED: ok_frac is content match rate (can be <1)
P4: cpu_over_wall reported; if ~1.0, wait still on-CPU (DMA may move bytes but
    still steals the core — Route A weak)
P5: decode under sustained VERIFIED DMA: mean ms/f ? 41.667
```

### A — DMA alone (must pass before pairing decode)
```bash
# on build host
make -C /home/flynnsbit/Projects/MisterPlex-wt-path arm-pl330-ingest-bench
# copy build/arm/ddr_pl330_ingest_bench to device /media/fat/misterplex/bin/

# on device — clean ps first (no rogue awk)
ddr_pl330_ingest_bench --dma-only --duration-s 25 --bank 1
# Accept only: pl330_verdict=VERIFIED_REAL_DMA  true_rc=0
# Reject: NO_REAL_DMA, ZERO_VERIFIED, INSTRUMENT_FAIL, fps fantasy
```

Optional short loops (still content-gated):
```bash
ddr_pl330_ingest_bench --len 1382400 --loops 40 --bank 1
```

### B — Decode under sustained verified DMA (architecture gate)
Only if A printed `VERIFIED_REAL_DMA`:
```bash
# terminal 1 — DMA traffic (verified loop)
ddr_pl330_ingest_bench --dma-only --duration-s 40 --bank 1

# terminal 2 — start after DMA prints pl330_transfer saw_exec=1
# use your real720p ~2600k asset; 300 frames; same recipe as clean 35.94 arm
ffmpeg_cpu_probe --label dec_under_dma --frame-bytes 1382400 -- \
  ffmpeg -hide_banner -nostats -i real720p_2600k.mp4 -an -frames:v 300 \
  -f rawvideo -pix_fmt yuv420p -
# (adjust to your exact working probe invocation)

# CLEAN control in same session (no DMA):
ffmpeg_cpu_probe --label dec_alone --frame-bytes 1382400 -- \
  ffmpeg -hide_banner -nostats -i real720p_2600k.mp4 -an -frames:v 300 \
  -f rawvideo -pix_fmt yuv420p -
```
**PASS Route A sketch:** dec_under_dma mean ≤ 41.667 ms/f **and** DMA arm still
`VERIFIED_REAL_DMA` for the whole window.  
**FAIL:** decode ≥ 41.667 or DMA drops to fake/zero verified — fabric owns pixels.

---

## (2) Falsify DecodeIntoBank (suspect trap)

Hypothesis: decoder stores + ref reloads from uncached bank (≥88 MiB/s store
ceiling, likely worse on reload) beats or loses to decode→RAM.

Proxy (pipe drain + write destination) — not full ffmpeg get_buffer2, but
bounds the **output write** term:
```bash
# build
make -C /home/flynnsbit/Projects/MisterPlex-wt-path arm-route-a-bank-probe
# device:
# RAM sink (control)
route_a_bank_probe --frames 300 --sink ram -- \
  ffmpeg -hide_banner -nostats -i real720p_2600k.mp4 -an -frames:v 300 \
  -f rawvideo -pix_fmt yuv420p -
# Bank sink Option-C bank1 (uncached)
route_a_bank_probe --frames 300 --sink bank --bank-phys 0x30300000 -- \
  ffmpeg -hide_banner -nostats -i real720p_2600k.mp4 -an -frames:v 300 \
  -f rawvideo -pix_fmt yuv420p -
```
If bank sink wall ≫ ram sink by ~copy cost or more, **DecodeIntoBank is a trap**
even before counting ref reloads. True get_buffer2-into-bank would be **worse**.

---

## Standing budget (cite these)
```
deadline 41.667 | decode 35.94 | CPU bank 14.978 structural | serial 50.9 FAIL
```
EOF

