# PMS no-upscale rule + library geometry survey (w-path)

**Date:** 2026-08-03 · **Host-only** · Branch `w-path-720p`  
**Parent finding accepted:** request 960×540 from 320×240 source → **320×240** (no upscale).

---

## 1) Stale FAIL artifacts

`prove_ladder_host/run_{540,360,540_trap}.txt` used **`metadata/1`** and an
older ffmpeg-header path (`rc=8` NO-DATA). **`run_all.txt`** used **`metadata/2`**
and is the authoritative PASS. Files are banner-annotated + `STALE_FAIL_README.md`.

---

## 2) Library source distribution (section 2, N=142)

| Bucket | Count | Notes |
|--------|------:|-------|
| 480p_class | **99** | mostly 624×480 (72), 720×480 (14), 640×480 (12) |
| 240p_class | **35** | 320×240 (15), 624×352 (14), 426×240 (4) |
| ≥1080p | **4** | 1920×1080×2, 1440×1080×2 |
| 360p_class | 3 | |
| 720p_class | **1** | single 1280×720 |

| Metric | Value |
|--------|------:|
| Can fill genuine **960×540** (w≥960 ∧ h≥540) | **5 / 142 (3.5%)** |
| Can fill genuine **1280×720** | **5 / 142** |
| Below 960×540 on either axis | **137 / 142 (96.5%)** |

**Verdict:** variable delivered geometry is the **common case**, not an edge.
HD-only “exact 540” is a **lab minority**. Fabric DE = content extent + ascal
is the right product shape for this library.

Artifacts: `library_source_survey/summary.txt`, `items.json`.

---

## 3) PMS rule (measured matrix, 19 cases)

**Statement to rely on:**

> `videoResolution=WxH` is a **ceiling fit box**, not an exact pin and **never an
> upscale target**. Delivered raster = **aspect-preserving scale of the source
> into `min(source_box, request_box)`**, with optional **±2 px** even/MB tweaks
> (e.g. 624×352 → 626×352). It is **not** “snap to nearest ladder step.”

| Source | Request | maxBR | Delivered | Class |
|--------|---------|------:|-----------|--------|
| 320×240 | 960×540 | 2000 | **320×240** | no upscale; =source |
| 320×240 | 640×360 | 1000 | **320×240** | no upscale |
| 624×480 | 960×540 | 2000 | **624×480** | =source (can't grow) |
| 624×480 | 640×360 | 1000 | **468×360** | AR fit into box (13:10) |
| 640×480 | 640×360 | 1000 | **480×360** | AR fit (4:3) |
| 720×404 | 960×540 | 2000 | **720×404** | =source |
| 720×404 | 640×360 | 1000 | **638×358** | AR fit |
| 624×352 | 624×480 | 2000 | **624×350** | classic anamorphic ceiling |
| 1280×720 | 960×540 | 2000 | **960×540** | downscale exact 16:9 |
| 1920×1080 | 960×540 | 2000 | **960×540** | downscale |
| 1920×1080 | 640×360 | 1000 | **640×360** | downscale |

**content_upscale_true = 0 / 19.** Full table: `pms_clamp_rule/matrix.txt`.

**Sanity-check on parent architecture:** Yes — for SD, **DE = delivered content
extent** and ascal→720 glass costs ARM nothing beyond decode-at-source. Exact
960×540 is only when source ≥ that box (and bitrate knee clears). PLXG untie is
the right mechanism for the **96.5%** case.

---

## 4) Contract guard

```bash
# SD subject (default metadata/1 = 320x240)
NO_UPSCALE_KEY=/library/metadata/1 SOURCE_W=320 SOURCE_H=240 \
  scripts/prove_ladder_delivery.sh no-upscale
# FAIL if delivered > source+2 or exact 960x540 from smaller source
```

Also included in `… prove_ladder_delivery.sh all` after HD rungs.

---

## 5) Daemon when delivered ≠ requested — **named gap**

**Evidence (code), not inference:**

1. `MEASURED_DELIVERY` stores measured WxH and logs mismatch — does **not**
   rewrite the play-time scale claim:

```text
media_player.cpp:~1500-1503
  measuredDeliveryW_.store(g.w);
  measuredDeliveryH_.store(g.h);
  // Do NOT overwrite ffmpegScaleSourceW_/H_ (play-time claim / request).
  // Measured lives in measuredDeliveryW_/H_ only — FINAL compares them.
```

2. DDR bank / reader size is fixed at session start from **DECODE tier** via
   `ddrFrameGeometryForFpgaPresent` → `rawW/rawH` / `frameBytes` — not from
   measured delivery:

```text
media_player.cpp:~2893-2916  ddrGeometry from decode tier; vfReq.coded_w = rawW
media_player.cpp:~3413-3416  frameBytes MUST track coded bank (rawW/rawH)
```

3. On mismatch: **ERROR** `DELIVERY_MISMATCH` / `GENUINE_540_FAIL` and
   FORCE_SCALE keeps pipe on **coded bank** shape (`force_scale_protects=1`).
   Play-time vf **cannot rebuild** mid-stream (`MEASURED_DELIVERY mid-stream change`).

4. **No PLXG / fabric geometry mailbox update** from `measuredDelivery*` in this
   path (mailbox still tied off per parent). Measured is **observability + loud
   log**, not a DE update.

**Bug name (if DE must track content):**  
`DELIVERED_GEOM_NOT_PROPAGATED_TO_STORAGE_OR_FABRIC` — daemon **assumes**
request/DECODE bank for present geometry; measured delivery is not a geometry
control plane. Compatible with old “scale into bank” product; **incompatible**
with “DE = content extent” until measured (or decision) drives bank + PLXG.

---

## 6) Parent commands (host)

```bash
# survey already at docs/evidence/p720-path-20260803/library_source_survey/
# clamp matrix: docs/evidence/p720-path-20260803/pms_clamp_rule/matrix.txt

PLEX_BASE=http://127.0.0.1:32400 PLEX_KEY=/library/metadata/2 \
  PLEX_TOKEN_FILE=… scripts/prove_ladder_delivery.sh all

NO_UPSCALE_KEY=/library/metadata/1 SOURCE_W=320 SOURCE_H=240 \
  PLEX_BASE=… PLEX_TOKEN_FILE=… scripts/prove_ladder_delivery.sh no-upscale
```
