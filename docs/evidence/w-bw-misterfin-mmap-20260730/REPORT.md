# w-bw — MiSTerFin mmap / PMS scale audit (host static + archive)

**Lane:** w-bw  
**SOURCE_SHA tip at write:** see git log on branch `w-bw`  
**Date:** 2026-07-30  
**Device access:** none (parent owns hardware)  
**Quartus:** none  

Related prior evidence (do not re-invent):
- `docs/evidence/p480/p480-bandwidth.md`
- `docs/evidence/p480/p720-bus-and-bitrate-margin.md`
- archive: `build/arm-sleep-evidence/W-FEED-arm-profile-ORIGINAL.txt`

## Licence

No MiSTerFin source was copied. MiSTerFin licence is not in this tree; treat as
external/GPL-family until parent verifies upstream.

## Finding A — `/dev/mem` cache class

Product path (`FpgaSpi::ensureDdrMap`):
- `open("/dev/mem", O_RDWR|O_CLOEXEC|O_SYNC)` when `ddrMemSync_=true` (default)
- `mmap(..., PROT_READ|PROT_WRITE, MAP_SHARED, ...)`

**Kernel pgprot for this MiSTer kernel:** not read → UNKNOWN from kernel source.

**Archive measure (device, not re-run here)** 624×480 I420 449280 B:
| mode | frame_ms | MiBps |
|------|---------:|------:|
| O_SYNC | 7.378 | 58.074 |
| no O_SYNC | 7.199 | 59.521 |
| no O_SYNC + cacheflush | 13.246 | 32.348 |

MiSTerFin's claimed ~1.5 GB/s write-through via fb driver mapping is **not**
reproduced on our `/dev/mem` frame window. O_SYNC≈no-sync (~2.5%).

## Bandwidth table (YUV420p = 1.5·W·H)

| tier | bytes | @30 fps MiB/s | ms @60 MiB/s | fatal @60 MiB/s? |
|------|------:|--------------:|-------------:|------------------|
| 320×240 | 115200 | 3.30 | 1.83 | no |
| 624×480 | 449280 | 12.85 | 7.14 | no @30; tight only if full stack eats rest |
| 1280×720 | 1382400 | 39.55 | 21.97 | no @24/30 pure-fill; **yes @60** (need ~79 MiB/s) |

Product store still **rejects** 1280×720 coded (`kDdrFrameStoreMaxWidth=640`).

## Finding B — PMS scale vs ARM scale

Code asks PMS:
`/video/:/transcode/universal/start.mp4?...&directPlay=0&directStream=0&videoResolution=<weak>`

| tier | PMS request | silicon coded (PRESENT=fpga) | residual ARM scale (`skip_identity`) |
|------|-------------|------------------------------|--------------------------------------|
| DECODE 320×240 | 320×240 @1000k | **624×480** | **always** (320≠624) |
| DECODE/lab 624×480 | 624×480 @2000k | 624×480 | skip if delivery matches |

Default: `FFMPEG_SCALE=skip_identity`, `FFMPEG_SWS_FLAGS` empty.
`FFMPEG_SCALE_ASSUME_MATCH` lab-only; unsafe on 320 ship path.

**PMS honor of videoResolution:** UNKNOWN without device stream probe.

## Doorbell order

`kickDdrDoorbell`: `dw[1]=hi` → `__sync_synchronize` → `dw[0]=PLXK` → barrier.
Payload: `memcpy` → `__sync_synchronize` → kick. **OK.**

## Process group

`setpgid` + `kill(-pid, ...)`. **OK.**

## Bench (parent runs on device)

```bash
make arm-ddr-bench
# scp build/arm/ddr_write_bench → device
/media/fat/misterplex/bin/ddr_write_bench --sync --geometry plex480p \
  --width 624 --height 480 --loops 1000 --bank 0
# expect MiBps line ~58 class if archive still holds
```

Or: `WIDTH=624 HEIGHT=480 GEOMETRY=plex480p LOOPS=1000 ./scripts/run_c2_ddr_bench.sh`

## Ranked wins

1. Bus alone does **not** explain ~90% CPU @480p (copy ~22% of 30 fps budget).
2. Ship 240p pays mandatory 320→624 swscale — magnitude unmeasured.
3. Flipping `DDR_MEM_SYNC=0` is **not** an evidenced 25× win.
4. Doorbell / pgkill already correct.

## Gate added

`tests/unit/test_ddr_bw_contracts.py` — freezes mmap O_SYNC default, doorbell
order, kill(-pid), universal URL flags, YUV byte arithmetic.
