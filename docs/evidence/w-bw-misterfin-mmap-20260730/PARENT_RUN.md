# Parent: DDR cache-policy probe (device)

**Bench commit:** see `git log -1 --oneline -- tools/ddr_write_bench.cpp` on branch `w-bw`  
**Binary:** static armhf `build/arm/ddr_write_bench`  
**Worker does NOT run these.** Parent owns 192.168.1.183.

## Pre-registered predictions (BEFORE device run)

| path | predicted MiBps | hit if |
|------|----------------:|--------|
| `/dev/mem` O_SYNC (product) | **50–70** | archive class (~58) |
| `/dev/mem` no O_SYNC | **50–70** | within ~10% of sync |
| `/dev/mem` no-sync + cacheflush | **25–40** | slower than plain |
| if mapping were fb-style write-through | **≥800** | would refute uncached class |
| `/dev/fb0` control (different phys) | **UNKNOWN** | measure only; do not assume 1.5 GB/s |

Prior archive (not this run): `W-FEED-arm-profile-ORIGINAL.txt` 624×480 O_SYNC MiBps=58.074.

**Correct product bytes (YUV420p, not RGB565):**
- 320×240 = **115200**
- 624×480 = **449280**
- 1280×720 = **1382400**

## Build + copy (host)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-bw
make arm-ddr-bench; echo "true rc=$?"
scp build/arm/ddr_write_bench root@192.168.1.183:/media/fat/misterplex/bin/ddr_write_bench
```

Prefer daemon stopped so bank pixels are not contested (bench does not kick doorbell).

## Device commands (capture full stdout)

```bash
B=/media/fat/misterplex/bin/ddr_write_bench
chmod +x "$B"

# A) product path O_SYNC — 480p I420
$B --sync --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0
echo "true rc=$?"

# B) product path no O_SYNC
$B --no-sync --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0
echo "true rc=$?"

# C) no-sync + ARM cacheflush
$B --no-sync --flush --format yuv420p --geometry plex480p --width 624 --height 480 --loops 1000 --bank 0
echo "true rc=$?"

# D) 320×240 I420 product path
$B --sync --format yuv420p --width 320 --height 240 --loops 1000 --bank 0
echo "true rc=$?"

# E) fb0 CONTROL (NOT frame store phys — smem_start will differ from 0x30000000)
$B --fb-copy --format yuv420p --width 320 --height 240 --loops 1000
echo "true rc=$?"
```

## Expected output keys

```
ddr_write_bench_meta ... prereg_devmem_mibps_lo=50 ...
devmem_map phys=0x30000000 ... O_SYNC=0|1 ...
smaps_tag=devmem_sync VmFlags: ...   # look for token "dc"
ddr_write_bench path=devmem_sync ... MiBps=NNN.NNN MBps=... frame_ms=...
```

## Scoring

1. If `VmFlags` contains `dc` → kernel marks don't-cache (uncached/device class).  
2. If MiBps ∈ [50,70] → HIT uncached-class prediction; MISS write-through.  
3. If MiBps ≥ 800 → HIT write-through-class; re-open transport theory.  
4. Compare fb0 `smem_start` to `0x30000000` — if unequal, fb route cannot replace frame-store map without a new driver.

Paste full logs back to w-bw for hit/miss publish.
