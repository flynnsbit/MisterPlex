# PMS delivered geometry for `540p` / `960x540` tier

**Lane:** w-path · **Date:** 2026-08-03 · **Method:** daemon-equivalent
`buildUniversalTranscodeUrl` + `plexFfmpegHeaders` (MiSTerPlex, baseline, level 31),
unique session, local docker PMS `127.0.0.1:32400`. Probe:
`docs/evidence/p720-path-20260803/probe_run/pms_720_daemon_path_probe.cpp` →
`build/pms_540_daemon_path_probe`. Artifacts: `probe_run/daemon_rk{2,7,83}_*`.

**Rule 0:** every WxH below is from decision XML and/or `ffprobe` / SPS
`trace_headers` on `start.mp4` samples — not inferred from the request alone.

**Parent broadcast (2026-08-03):** independently confirmed the same SPS on
`proxy_960x540.mp4` — coded **544**, display **540**, bank **777600** stands;
ffprobe `coded_height=540` is post-crop and must not be trusted as MB height.
Bitstream-ring ABI now records 544 for a future fabric decoder
(`ddr_bitstream_ring.hpp` `kRing540pSps*`). Option-C bank predicate remains
**w-mem only** — path does not duplicate that fix.

---

## 1) Headline — what PMS returns for the product tier

| Request | Source asset | maxBR | **Delivered display** | **ffprobe coded_*** | SAR | Profile / level | Decision |
|--------:|--------------|------:|----------------------:|--------------------:|-----|-----------------|----------|
| 960×540 | rk2 Test 1080p (1920×1080 16:9) | 1500 | **720×404** | 720×404 | 404:405 | CB L31 | transcode |
| 960×540 | rk2 | **2000** | **960×540** | **960×540** | **1:1** | CB L31 | transcode |
| 960×540 | rk2 | 2500 | 960×540 | 960×540 | 1:1 | CB L31 | transcode |
| 960×540 | rk2 | 3100 | 960×540 | 960×540 | 1:1 | CB L31 | transcode |
| 1280×720 | rk2 | 3100 | 1280×720 | 1280×720 | 1:1 | CB L31 | transcode |
| 960×540 | rk7 Test 720p (1280×720 16:9) | 1500 | 720×404 | 720×404 | 404:405 | CB L31 | transcode |
| 960×540 | rk7 | **≥2000** | **960×540** | **960×540** | **1:1** | CB L31 | transcode |
| 960×540 | rk83 Promo 1440×1080 **4:3** | 1500–3100 | **720×540** | 720×540 | n/a | CB L31 | transcode |
| 1280×720 | rk83 4:3 | 3100 | **960×720** | 960×720 | n/a | CB L31 | transcode |

SD sources (rk9 BBB 624×352, rk10 720×480) **cannot** produce 960×540 — ceiling is
source size (measured 626×352 / 852×480). Use HD 16:9 (rk2 / rk7 / equivalent) for PLAYING.

**Product claim that is now evidence-backed:**

```
DECODE=960x540 + weak maxBR≥2000 + HD 16:9 source
  → PMS transcode Constrained Baseline L3.1
  → display = coded (ffprobe) = 960×540, SAR 1:1, DAR 16:9
  → I420 publish size = 960*540*3/2 = 777_600 B
```

`videoResolution` remains a **ceiling** (and bitrate is a second ceiling): maxBR=1500
on the same URL yields **720×404**, not 540p. 4:3 sources never fill 960 width.

---

## 2) H.264 MB alignment — 540 vs 544 (settled)

Parent concern: 540 & 15 = 12, so coded height “should” be 544 and I420 783_360.

**SPS (`ffmpeg -bsf:v trace_headers`) on rk2 maxBR=2000 body:**

```
pic_width_in_mbs_minus1            = 59   →  60*16 = 960
pic_height_in_map_units_minus1     = 33   →  34*16 = 544
frame_cropping_flag                = 1
frame_crop_bottom_offset           = 2    →  2*2   = 4 luma lines cropped
⇒ display height = 544 − 4 = 540
```

| Layer | WxH | I420 bytes | Who cares |
|-------|-----|------------|-----------|
| SPS MB grid (pre-crop) | 960×**544** | **783_360** | Decoder DPB only |
| ffmpeg decode output / ffprobe | 960×**540** | **777_600** | **ARM DDR publish** |
| Frozen bank / w-mem payload | 960×**540** | **777_600** | Fabric reader |

**ffprobe reports `coded_height=540`** (post-crop). The 544-line buffer never leaves
libavcodec into our rawvideo path. **Do not size the DDR bank to 783360.**

Scaler: display 960×540 → glass 1280×720 is exact **4/3** on both axes — no
extra height crop from 544→720. Crop already happened in the bitstream.

Constants: `kPlex540pSpsMbHeight=544`, `kPlex540pSpsCropBottomLuma=4`,
`kPlex540pYuv420pBytes=777600` in `ddr_frame_layout.hpp`.

---

## 3) What ARM publishes into the DDR bank

| Question | Answer | Evidence |
|----------|--------|----------|
| Coded MB or display? | **Display after ffmpeg crop = 960×540** | SPS crop + ffprobe; `kPlex540pYuv420pBytes` |
| Matches fabric expectation? | **Must be 960×540 content window / 777600 B payload** | Agrees with lane freeze; **not** 544 |
| identity_skip when genuine? | Yes only if `isGenuine540pDelivery(w,h)` | `pms_delivery_geom.hpp` |
| Does host already present 540 into FPGA? | **NO — integration gap** | see §5 |

Decode path produces YUV planes at decoder `width`×`height` (540). Publish path
must use that size for bank packing when the paired RBF is the 540 fabric.

---

## 4) Parent device-side verification recipe (run when box is up)

**Precondition:** daemon from `w-path-720p` ≥ `8e62f61b`, conf
`DECODE=960x540` + `OSD_CONTROL=off`, HD 16:9 ratingKey (lab: 2 or 7),
`MiSTerPlex` profile installed on PMS.

### A — Confirm the *request* (daemon log)

```bash
ssh root@$MISTER_HOST 'grep -E "content resolution=|GEOM requested_pms=|DECODE adopted" \
  /media/fat/misterplex/misterplexd.log | tail -20'
```

Expect: `content resolution=960x540 source=conf/--decode` and
`GEOM requested_pms=960x540`.

### B — Confirm *delivered* stream geometry (authoritative)

On the device (or build host with the same URL the daemon opened), sample the
live universal `start.mp4` (or the file ffmpeg is reading) and run:

```bash
# BODY = path to a drained start.mp4 sample (>= ~1 MB), or pipe from the live URL
# NEVER log X-Plex-Token. Prefer curl -K with a mode-0600 cfg that is deleted after.

ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,coded_width,coded_height,\
sample_aspect_ratio,display_aspect_ratio,profile,level,pix_fmt,r_frame_rate \
  -of default=nokey=0:noprint_wrappers=1 "$BODY"
```

**PASS (genuine 540p delivery):**

```text
width=960
height=540
coded_width=960
coded_height=540
sample_aspect_ratio=1:1
display_aspect_ratio=16:9
profile=Constrained Baseline
level=31
```

**FAIL examples (do not score glass as 540 path):**

```text
height=404          # bitrate ceiling (raise WEAK_BITRATE / check maxBR≥2000)
width=720 height=540  # 4:3 source aspect fit — wrong asset class
height=352 or 480     # SD source or wrong tier
```

### C — Optional SPS crop proof (settles 544 vs 540 on device)

```bash
ffmpeg -hide_banner -i "$BODY" -c copy -bsf:v trace_headers -f null - 2>&1 \
  | grep -E 'pic_width_in_mbs|pic_height_in_map|frame_crop' | head -20
```

Expect `pic_height_in_map_units_minus1=33` (544) and `frame_crop_bottom_offset=2`
(→ display 540). Bank sizing still uses **540**, not 544.

### D — I420 byte check

```bash
python3 - <<'PY'
w,h=960,540
print("I420_display", w*h*3//2)   # 777600
print("I420_sps_mb", 960*544*3//2)  # 783360 — not used for DDR
PY
```

---

## 5) Integration contract with w-mem / w-scaler (must agree)

| Owner | Contract point | Status |
|-------|----------------|--------|
| **w-path** | Request 960×540, L31, baseline, weak 2000; genuine gate exact 960×540 | **DONE** (measured) |
| **w-path** | Publish **display** 960×540 / 777600 B after ffmpeg crop | **Intended**; see gap |
| **w-mem** | Bank holds ≥777600; Option-C select must not require `coded_w>=1280` only | Parent found predicate bug — **w-mem fix required** |
| **w-mem / w-path** | `ddrFrameGeometryForFpgaPresent()` today **ignores decode** and returns **480p 624×480** (`ddr_frame_layout.hpp`) | **BLOCKER for PLAYING** until present geometry tracks 540 fabric RBF |
| **w-path** | `ddrFrameStoreAcceptsResolution(960,540)` is **false** (MB-align + max 640×480 legacy) | Parse path special-cases 540/720; recon F1 pack path still gated — pair with present flip |
| **w-scaler** | Content window **960×540 → 1280×720** (1.333×), display-based not 544 | Align on 540 |

**Explicit agreement statement for w-mem:**

> ARM publishes **960×540 YUV420p = 777600 bytes** per frame (ffmpeg display after
> SPS bottom crop). Fabric reader stride/height must match **540**, not SPS MB **544**.
> Bank capacity must be ≥777600 (legacy 512 KiB is enough for payload; Option-C
> windowing must select a bank that fits 540-wide frames, not only ≥1280).

---

## 6) Deploy answers (restated)

1. **Daemon branch:** `w-path-720p` worktree
   `/home/flynnsbit/Projects/MisterPlex-wt-path`, commit **≥ `8e62f61b`**
   (tip moves; rebuild from tip). `make arm-plexd` →
   `scripts/deploy_misterplexd.sh build/arm/misterplexd`.
2. **Tier select:** `DECODE=960x540` + **`OSD_CONTROL=off`** (no OSD 540 slot).
   Verify: `content resolution=960x540 source=conf/--decode` and
   `GEOM requested_pms=960x540`.
3. **Bitrate:** `weakBitrateKbps=2000` = quality default **and** measured geometry
   knee on this PMS for 16:9 HD. No silent reject below; WARN only. L31 + baseline.
   Below 2000 → measured **720×404** (not 540).

Full pairing card: `PARENT_DEPLOY_PAIR_540P.md`.

---

## 7) What this does *not* claim

- Not true 720p source.
- Not measured on the MiSTer device (box down); local PMS + daemon URL shape only.
- Not a fix of `ddrFrameGeometryForFpgaPresent` / Option-C predicate — those remain
  open with w-mem for the fit.
- Direct Play of native 720p was not re-run here; product path is **transcode 540**.
