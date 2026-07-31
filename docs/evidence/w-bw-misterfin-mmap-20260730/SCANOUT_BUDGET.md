# CRITICAL — FPGA scanout DDR read budget vs ARM mmap write

**Lane:** w-bw  
**SHA:** (see git log on `w-bw`)  
**Rule 0:** every number below is either pure arithmetic from quoted RTL constants or a cited parent/archive artifact.

---

## Decisive verdict (scanout pure bandwidth)

**The DDR scanout read budget is comfortably met. Bulk bandwidth is NOT the cause of `rd_miss_now` black prefixes.**

| tier | required | peak f2sdram 64b@90 MHz | Y-line fill (lat=12) | line period | Y fill / line |
|------|---------:|------------------------:|---------------------:|------------:|--------------:|
| 320×240 YUV420p @60 | **6.91 MB/s** | **720 MB/s** | **0.578 µs** | **63.8 µs** | **0.91%** |
| 624×480 YUV420p @60 | **27.0 MB/s** | **720 MB/s** | **1.00 µs** | **63.8 µs** | **1.57%** |

Headroom peak/required: **104×** (320@60), **27×** (624@60).

If fill started exactly at DE open (no prefetch), lat=12 would blacken only ~6 px (320) / ~10 px (624) at 10 MHz `ce_pix` — **not** a ~420 px capture-class prefix and **not** a full-line miss. Parent's `max_left_miss_run=64` in shear even at `rd_delay=2` is therefore **not** explained by bulk transfer time.

Gate: `python3 tests/unit/test_ddr_scanout_budget.py` → must print `VERDICT: ... COMFORTABLY MET`.

### What this redirects

- **w-fit** should stop treating “DDR too slow to supply scanout” as the primary root cause for pure bandwidth.
- Remaining miss class is **prefetch / hit-path / CDC / scheduler** (lines not valid in M10K when beam arrives), or a **geometry/mapping** bug — bandwidth math cannot kill those.
- Shear sim currently **PASS CLEAN** product_slow/fast while still printing `max_left_miss_run=64` — the clean criterion does **not** fail on left_miss_run (observed main-tree binary run). That is a **test-gap**, not a BW proof.

---

## Clocks & line timing (quoted)

| signal | source | value |
|--------|--------|------:|
| `clk_sys` | `pll_0002.v` `output_clock_frequency0` | **20.000000 MHz** |
| `clk_ddr` | `pll_0002.v` `output_clock_frequency2` | **90.000000 MHz** |
| `ce_pix` non-scandouble | `colorbars.sv` toggles | **10 MHz** pixel rate |
| `H_DE` | `colorbars.sv` | **529** |
| `H_LAST` | `colorbars.sv` | **637** → **638** ce_pix/line |
| line period non-sd | 638 / 10e6 | **63.8 µs** |
| DDRAM beat | 64-bit @ `clk_ddr` | **8 B × 90e6 = 720 MB/s** peak streaming |

`ddr_frame_store.sv`: `Y_LINE_QWORDS = CODED_W/8`, `C_LINE_QWORDS = CODED_W/16`, `LINE_COUNT=8`, `DDR_BURST_MAX=128`.  
Miss paint: `rd_miss_now = rd_active && rd_visible && has_frame && (!y_hit_now || !c_hit_now)` → RGB 0.

---

## ARM `/dev/mem` cache policy (separate path)

Product map (`fpga_spi.cpp` `ensureDdrMap`):

```text
open("/dev/mem", O_RDWR|O_CLOEXEC|O_SYNC)  // ddrMemSync_=true default
mmap(..., PROT_READ|PROT_WRITE, MAP_SHARED, fd, phys_base=0x30000000)
```

| claim | status |
|-------|--------|
| fd + flags as above | **EVIDENCED** |
| PTE uncached vs WC/WT | **UNKNOWN until parent smaps + MiBps** |
| MiSTerFin 60 MB/s vs 1.5 GB/s | **THEIRS — NOT ours** |
| Archive W-FEED 624 I420 O_SYNC | **58.074 MiB/s** (prior device) |

**Critical separation:** FPGA scanout reads via **DDRAM bridge @ 90 MHz**. ARM mmap write cacheability does **not** set FPGA read bandwidth. Even if ARM writes at ~60 MiB/s, that is a **push** cost, not scanout supply rate.

### Pre-registration (ARM bench, before parent run)

| path | predicted MiBps | HIT if |
|------|----------------:|--------|
| `/dev/mem` write O_SYNC | 50–70 | archive class |
| `/dev/mem` write no-sync | 50–70 | ~same as sync |
| `/dev/mem` read | 50–70 (same class hyp.) | measure |
| WT-class surprise | ≥800 | would refute uncached class |

---

## Push-time contradiction (settled)

| number | what it is | path |
|--------|------------|------|
| **194–220 ms** | comment in `sendFileTx` @320×240 **RGB565 153600 B** | **SPI** F1 lab (~0.79 MB/s) — **NOT product** |
| **~4.1 ms** mean | parent p480 A/B `ddr_push_ms` 240p | **product DDR** present |
| **~8.5 ms** mean | parent p480 A/B `ddr_push_ms` 480p | **product DDR** present |
| **~7.2 ms** | W-FEED pure memcpy 624 I420 | DDR fill only |

**194–220 ms is INVALID as product push.** Parent 4.1/8.5 ms supersede it for live present. Do not average SPI with DDR.

---

## Parent commands (device — parent only)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-bw
make arm-ddr-bench; echo "true rc=$?"
scp build/arm/ddr_write_bench root@192.168.1.183:/media/fat/misterplex/bin/ddr_write_bench
# on device:
B=/media/fat/misterplex/bin/ddr_write_bench
$B --sync --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0; echo "true rc=$?"
$B --no-sync --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0; echo "true rc=$?"
$B --read --sync --format yuv420p --width 320 --height 240 --loops 1000 --bank 0; echo "true rc=$?"
$B --fb-copy --format yuv420p --width 320 --height 240 --loops 1000; echo "true rc=$?"
```

Score: `MiBps=`, `rw=write|read`, `VmFlags:`, `smaps_tag=`, fb0 `smem_start` vs `0x30000000`.

Or: `scripts/parent_ddr_cache_probe.sh` (still write-matrix; add `--read` by hand).

---

## Ranked expected wins

1. **Prefetch/hit-path fix on FPGA** (if miss persists with BW headroom) — top for garbage video.  
2. **ARM mmap WT/WC** — only helps **push CPU time**; does not fix scanout miss paint.  
3. **PMS true coded size** — decode CPU, orthogonal to miss paint.  
4. Dropping `O_SYNC` alone — archive ~2.5% only.
