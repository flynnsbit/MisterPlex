# p480-bandwidth — DDR frame push cost (host analysis)

**SOURCE_SHA:** `58de897f9fbfe536f0f6654250cd4d6242261983`  
**Lane:** ARM/host only (no device access this run)  
**Date:** 2026-07-30

## Pre-registered predictions (before re-read)

| ID | Prediction | Status |
|----|------------|--------|
| P1 | Comment at `fpga_spi.cpp:1263` (~194–220 ms) is **SPI F1 RGB565 whole-frame**, not product DDR I420 | **HIT** — quoted below |
| P2 | 153600 B = 320×240×2 RGB565, not I420 115200 B | **HIT** |
| P3 | Product path is DDR memcpy+doorbell; wall cost ≪ SPI | **HIT** (prior device artifact + code) |
| P4 | O_SYNC vs no-sync DDR memcpy differs by ≫2× | **MISS** — device archive: 7.378 vs 7.199 ms/f (~2.5%) |
| P5 | 480p I420 push alone cannot sustain ~30 fps | **MISS as bus-bound claim** — at ~7.2 ms/f DDR write alone caps ~139 fps; product present was ~10.4 ms/f (~96 fps cap) before decode |

## 1. What the 194–220 ms number measured

Quoted from `arm/misterplexd/fpga_spi.cpp` inside `FpgaSpi::sendFileTx` (SPI file-TX path):

```text
// Lab measure @320×240 (153600 B): 8 KiB→~220 ms, 32 KiB→~194 ms, 128 KiB→~196 ms.
// SPI is the ceiling (~0.8 MB/s); DDR3 bulk (3.1b) needed for real-time F1.
const size_t chunk = 32768;
```

Evidence from the same function:

- Timer wraps the **entire** `sendFileTx` call (`t0` before SPI exclusive, `t1` after `setDownload(0)`).
- Payload size in the comment is **153600 B = 320×240×2** (RGB565 LE), produced by `sendRgb24Frame` → `rgb24ToRgb565Le` → `sendFileTx`.
- Chunk-size sweep (8/32/128 KiB) yields nearly constant whole-frame time → **SPI bandwidth-bound**, not per-transaction-bound at those chunk sizes.
- Implied throughput: 153600 B / 0.194 s ≈ **0.79 MB/s** (matches the comment’s ~0.8 MB/s).

**This path is not product playback.** Product F1 is DDR YUV420p (`sendDdrFrame` / `sendYuv420pFrameDdr`). `sendFileTx` refuses index 1 (frame slot) and tells callers to use DDR.

Default layout note: `fpga_spi.hpp` still constructs `makeDdrFrameLayout(320, 240)` as the initial DDR layout; runtime switches geometry via `setDdrFrameLayout`.

## 2. Byte volume per tier (from `ddr_frame_layout.hpp`)

| Role | Geometry | Bytes | Formula / constant |
|------|----------|------:|--------------------|
| Product coded 240p I420 | 320×240 | **115200** | `w*h*3/2` |
| Comment SPI RGB565 | 320×240 | **153600** | `w*h*2` (not I420) |
| Lab coded 480p I420 | **624×480** | **449280** | `kPlex480pYuv420pBytes` |
| Presented scanout only | 640×480 | n/a as decode | `PresentedMistake` if used as DECODE |
| 480p RGB565 (legacy synth) | 624×480 | 599040 | `kPlex480pRgb565Bytes` |

Coded/presented split (quoted contract):

- coded **624×480** — H.264 payload + DDR bank layout  
- display **618×480** — after right crop 6  
- presented **640×480** — VGA after 11+11 pillarbox  

Ratio I420 480p/240p: `449280/115200 = 3.900`.

## 3. Product DDR push: what `lastPushMs` covers

`sendDdrFrame` (`fpga_spi.cpp`) times wall from entry to exit and fills `DdrTiming`:

| Field | Operation |
|-------|-----------|
| `prep_wait_us` | PLXD bank-release wait **or** PLXD-absent `usleep(1500)` (+ optional same-bank floor) |
| `copy_us` | `memcpy` of **full** `frame_bytes` into mapped bank |
| `flush_us` | optional `cacheflush` when `!ddrMemSync && ddrMemFlush` |
| `doorbell_us` | doorbell kick (steady) or first-frame SPI/doorbell probe |
| `post_wait_us` | `usleep(500)` only when `!first && !plxdUsed` |
| `total_us` / `lastPushMs_` | sum wall for whole publish |

Hot path copy (quoted):

```text
std::memcpy(ddrMap_ + bankOff, payload, len);
__sync_synchronize();
```

**Not** the SPI chunk loop. Observed ~29.7 fps cannot come from a 194 ms SPI push; it requires the DDR path (or a non-frame path). That is a code/path fact, not an fps measurement from this lane.

## 4. `ddrMemSync` cost

Code (`ensureDdrMap`):

- `ddrMemSync_==true` (default, conf `DDR_MEM_SYNC=1`): `open("/dev/mem", O_RDWR|O_CLOEXEC|O_SYNC)`
- `false`: no `O_SYNC`; optional `DDR_MEM_FLUSH` → ARM `cacheflush` before doorbell

**Device archive** (not remeasured this lane) —  
`build/arm-sleep-evidence/W-FEED-arm-profile-ORIGINAL.txt`, 624×480 I420, 1800 loops:

| Mode | frame_ms | MiB/s | fps30 budget |
|------|---------:|------:|-------------:|
| O_SYNC | **7.378** | 58.074 | 22.1% |
| no O_SYNC | **7.199** | 59.521 | 21.6% |
| no O_SYNC + cacheflush | **13.246** | 32.348 | 39.7% |

**Evidence-backed claim:** for this length, O_SYNC vs plain mmap write is ~same; **cacheflush nearly doubles** copy cost. Default product (`DDR_MEM_SYNC=1`, flush off) matches the ~7.2–7.4 ms row for pure bank fill (no PLXD wait, no doorbell probe loop).

Product present (same archive summary / FEED): mean `ddr_total_us_p≈10465` (~10.41 ms/f) including prep/post — **larger than pure memcpy** because of bank-wait path components (PLXD status for that run was **not** in the log; see RULE0 retractions — do not claim PLXD-absent without `ddr_plxd_used_x100_p`).

## 5. Bandwidth-bound vs per-transaction; 480p scaling

**SPI (retired F1):** chunk sweep flat → bandwidth-bound ~0.8 MB/s. At that rate I420 240p alone would be ~144 ms/f (~7 fps) — consistent with “DDR required for real-time.”

**DDR bank fill (device archive, 449280 B):** ~58–60 MiB/s sustained write into FPGA window.

If **bandwidth-bound** at 59.521 MiB/s (no-sync row):

| Tier | Bytes | Extrapolated copy ms | Copy-only fps cap |
|------|------:|---------------------:|------------------:|
| 320×240 I420 | 115200 | **1.85** | ~542 |
| 624×480 I420 | 449280 | **7.20** (measured) | ~139 |

Host-only `ddr_write_bench --host-copy` (this run, x86, not ARM comparable): 320×240 0.005 ms/f vs 624×480 0.007 ms/f — host DRAM is not the product bus; **do not use host_copy as ARM fps proof**.

**Bound type for product:** pure DDR fill looks **byte-volume / bus bandwidth** limited (~60 MiB/s), not a fixed ~200 ms/transaction. Fixed costs that **do not** scale with pixels: PLXD poll, doorbell write, optional post `usleep(500)`, first-frame kick probe. Those add to `lastPushMs` but are small vs 7 ms copy at 480p **if** PLXD is live and prep≪1 ms (unproven without new `present_profile`).

**Crux:** 480p is **not** bus-capped below ~30 fps by DDR memcpy alone on the archived MiSTer measurement. Headroom question moves to **decode + scale + pipe + present waits + GDM/CPU** (GDM storm fixed v10). Bitrate margin comment in `osd_menu.hpp:114-116` (“millisecond-scale decode margin” / 2000 kbps floor) was characterized under GDM burn — **flagged as possibly stale; harness must settle; bitrate floor not changed here.**

## 6. What still requires `w-device` (exact recipe)

Host cannot open MiSTer `/dev/mem` or sample live present. Run on device:

```bash
# A) Pure DDR fill both tiers (no SPI, no daemon restart required if careful)
make arm-ddr-bench
# scp build/arm/ddr_write_bench → device
LOOPS=1000 ./scripts/run_c2_ddr_bench.sh   # WIDTH=320 HEIGHT=240
WIDTH=624 HEIGHT=480 GEOMETRY=plex480p LOOPS=1000 ./scripts/run_c2_ddr_bench.sh

# B) Product present split (needs PRESENT=fpga, PRESENT_PROFILE=1, one cast)
# Prefer tests/hw/test_p480_ab_harness.sh (this lane) — forces coded tier via conf
# and emits CPU + frames + av_drift + present_profile + optional HDMI avsync.

# C) Must capture (Rule 0):
#   ddr_copy_us_p, ddr_total_us_p, ddr_plxd_used_x100_p, lastPushMs / f1ms
#   decode=WxH on media: frames= lines
#   SOURCE_SHA of deployed misterplexd + RBF md5
```

**Prediction for device A (publish miss later):** 320 I420 O_SYNC frame_ms ≈ 1.8–2.5 ms; 624 ≈ 7.0–7.8 ms; ratio ≈ 3.5–4.0 (bandwidth). If 240p stays near 7 ms, bound is fixed overhead → **publish MISS** and re-open analysis.

## 7. Bottom line (evidence-only)

| Question | Answer with evidence |
|----------|----------------------|
| Are 194–220 ms still the per-frame push? | **No** — SPI RGB565 whole-frame lab, retired path |
| Real product push cost today? | **Unknown on live post-GDM device this lane**; best archive: **~7.2 ms** memcpy 480p I420, **~10.4 ms** product present total |
| 480p bus-bound below realtime? | **Not by archived DDR fill** (~139 fps cap copy-only) |
| Decode-bound? | Live harness A/B (parent): 480p **89.8 %onecpu** total — CPU-bound class |
| Change 2000 kbps floor? | **No** — see `p720-bus-and-bitrate-margin.md` |

## 8. Follow-on (720p bus + bitrate)

See **`p720-bus-and-bitrate-margin.md`**: 720p I420 copy **22.1 ms** @ 59.521 MiB/s (bus not blocker @24/30); product store **rejects** 1280×720; keep 2000 kbps.
