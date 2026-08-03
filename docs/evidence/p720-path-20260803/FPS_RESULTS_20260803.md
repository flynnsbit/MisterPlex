# PMS frame-rate control — measured results (w-path, 2026-08-03)

**Fixture:** local PMS ratingKey **rk142** — `MiSTerPlex Test 1080p2997 (2026).mp4`
(1080p, source `30000/1001`). Control: **rk2** (24 fps film).

**Request baseline:** daemon-equivalent universal start @ `videoResolution=960x540`,
`maxVideoBitrate=2000`, `videoLevel=31`, `videoProfile=baseline`, `directPlay=0`.

**Budget (parent, tight 960×540 decode+sws+copy):** **34.50 ms**.

| fps | deadline ms | vs 34.50 | status |
|----:|------------:|---------:|--------|
| 24 | 41.667 | +7.16 | PASS (predicted) |
| 25 | 40.000 | +5.50 | PASS (predicted) |
| 29.97/30 | 33.333 | **−1.17** | **FAIL** (unfalsified on device; host math) |

---

## Predictions vs measured

| ID | Prediction | Result | Evidence |
|----|------------|--------|----------|
| **P1** | PMS exposes a frame-rate lever | **PARTIAL HIT** | Query params **MISS**. Client-Profile-Extra `video.frameRate` upperBound **HIT**. MiSTerPlex.xml already has UpperBound 30 (allows 29.97; does not force 24). |
| **P2** | No cap → pass-through source rate | **HIT** | rk142 nocap: decision `frameRate=29.97…`, ffprobe `r_frame_rate=30000/1001` (MiSTerPlex) / `2997/100` (Plex Web), geometry still **960×540**. |
| **P3** | Cap → ~24 delivery | **HIT** (Extra only) | `X-Plex-Client-Profile-Extra` with `name=video.frameRate&value=24` → decision `frameRate=24`, ffprobe `24/1`. Works for **both** `MiSTerPlex` and `Plex Web` profile names. |
| **P4** | Fallback tier if uncapped 30 | **Revised** | See below. Pre-reg **853×480** is **not** exact 2/3 of 1280 (1280×2/3=853.⅓) and 853 is not MB-aligned. |

Artifacts: `probe_run/fps2_*_{decision.xml,ffprobe.json}` (bodies not committed).

### Levers that do **not** work (lab PMS)

Universal query params (all still delivered 29.97 on rk142):

- `maxFrameRate=24`
- `frameRate=24`
- `videoFrameRate=24`
- `maxVideoFrameRate=24`

Incomplete Extra form (codec scope only, no transcode-target scope) also **MISS**
(`fps2_web_extra24b`).

### Lever that **works**

```
X-Plex-Client-Profile-Extra:
  add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.frameRate&value=24&isRequired=true)+
  add-limitation(scope=videoTranscodeTarget&scopeName=h264&scopeType=videoCodec&context=streaming&protocol=http&type=upperBound&name=video.frameRate&value=24&isRequired=true)
```

With **MiSTerPlex** profile name + frame-rate-only Extra: still Constrained Baseline,
geometry 960×540, rate **24/1**. Full Extra remains suppressed (drops VideoEncodeFlags).

**Daemon product wire (this commit):**

- `WeakLadder::maxVideoFrameRate` — 540p ladder default **24** (`kPlex540pMaxVideoFrameRate`)
- MiSTerPlex headers send **frame-rate-only** Extra when `maxVideoFrameRate > 0`
- Conf override: `WEAK_MAX_FRAME_RATE=24|0|…` (explicit wins over ladder default)
- GEOM log: `max_video_frame_rate=%d`

---

## Delivered geometry @ 29.97 (uncapped)

Same ceiling rules as 24 fps 540 tier:

- HD 16:9 + maxBR≥2000 → **960×540** display (ffprobe), SAR 1:1, CB L31
- Rate = **source rate** (30000/1001)
- I420 publish after libav crop: **777600 B** (SPS MB height 544 is not ARM payload)

---

## Fallback if we cannot / will not cap fps

Primary ship recommendation for 540p glass: **keep 960×540 and cap PMS at 24 fps**.
That preserves exact **4/3** fabric scale (`540×4/3=720`) and the measured +7.16 ms
margin. PMS frame-drop/retime is preferred over ARM 30 fps FAIL.

If uncapped 29.97/30 must play without a rate pin:

| Tier | Rational scale to 1280×720 | I420 B | Scaled total ms* | vs 33.333 | Notes |
|------|----------------------------|-------:|-----------------:|----------:|-------|
| **960×540** | **exact 4/3** | 777600 | 34.50 | **−1.17 FAIL** | Product glass; needs fps cap |
| **640×360** | **exact 2×** | 345600 | ~15.3 | **+18 PASS** | Softest glass; only exact half |
| 853×480 | **not exact** (1280×2/3=853.⅓) | ~614k | ~27.3 | +6.0 | Width not integer 2/3; 853 not MB-aligned |
| 854×480 | not exact 2/3 | ~615k | ~27.3 | +6.0 | Parent proxy; anisotropic scale |
| 624×480 | product 480 canvas | 449280 | ~19.9 | +13.4 | Legacy path; not 4/3 to 720 |

\*Host arithmetic from parent 960×540 baseline (decode+sws ∝ pixels, copy ∝ bytes @
same 88 MiB/s class). **Not device-measured** — mark as estimate.

**Recommended geometry fallback if fps cap refused:** **640×360** (exact 2× to
1280×720). Do **not** invent an 853 tier as “exact 2/3” — it isn’t. 480p product
(624×480) remains the safe non-720-glass path.

Auto step-down policy (proposed, not implemented as runtime detector yet): when
library/`Stream@frameRate` implies ≥29.97 **and** `WEAK_MAX_FRAME_RATE` is 0 **and**
tier is 540p → either refuse 540 or fall to 640×360 / 480p. Prefer fixing the request
(cap=24) over silent geometry demotion.

---

## Device recipes (parent runs when box is up)

### A) Confirm request cap

```bash
grep -E 'GEOM requested_pms=|max_video_frame_rate=' /media/fat/misterplex/misterplexd.log | tail -5
# expect: requested_pms=960x540 ... max_video_frame_rate=24
```

### B) Confirm delivered rate + geometry (live Part/transcode URL or saved body)

```bash
# After play starts — pull a few MB of the active session URL (or use PMS
# TranscodeSessions), then:
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,coded_width,coded_height,r_frame_rate,avg_frame_rate,profile,level \
  -of json /path/to/body.bin

# PASS 540@cap: width=height=960x540, r_frame_rate=24/1 (or 24/1-class)
# FAIL uncapped 29.97: r_frame_rate=30000/1001 with same 960x540
#
# Do NOT trust ffprobe coded_height as SPS MB height (540 is post-crop).
```

### C) Disable cap for A/B (expect budget FAIL at 30)

```ini
DECODE=960x540
OSD_CONTROL=off
WEAK_MAX_FRAME_RATE=0
```

---

## Honest gaps

- Device ARM 29.97 vs 24 timing not re-measured after daemon storage fix — host
  34.50 ms vs 33.333 is the standing prediction.
- PMS may retime 29.97→24 with judder; glass quality not scored here.
- `MiSTerPlex.xml` UpperBound remains **30** so non-540 tiers are not globally forced to 24.
