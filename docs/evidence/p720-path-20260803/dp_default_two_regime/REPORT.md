# DP-default + two-regime — live PMS proof (w-path)

**Host:** PMS `127.0.0.1:32400` (build host). Token via mode-0600 curl `-K` only.  
**Date:** 2026-08-03. Parent miss #13 framing correction applied.

## Pre-registered predictions

| ID | Prediction | Result |
|----|------------|--------|
| P1 | SD rk=36 `directPlay=1` + full identity → `decision=directplay`, baseline | **HIT** `constrained baseline` 624×480 mp4 |
| P2 | HD rk=2 `directPlay=0` @1280×720 → `decision=transcode`, ~1280×720 | **HIT** transcode **1280×720** mpegts; profile **constrained baseline** (this PMS+MiSTerPlex — not High) |
| P3 | Thin headers (token+session only) → HTTP 400 / empty | **HIT** `http_code=400` body 89 B (token-only curlrc). Note: shared `/tmp/pms.curlrc` already injects full identity — thin test must not use it. |
| P4 | SD DP with `videoResolution=1280x720` still native | **HIT** still 624×480 directplay (no upscale) |

## Why HD must not DP

`directPlay=1` on rk=2 → `decision=directplay` **1920×1080** (p2b). That is the DPB/downscale trap parent named. Regime `media_w>1280 \|\| media_h>720` forces xcode.

## Daemon policy landed

- `preferDirectH264ForContent`: default **true** when conf unset
- `selectPlayDeliveryRegime(media_w,h,allow,h264)` from **item geometry** (no ratingKey hardcode)
- SD → Part DP; HD>720 → universal 720p ladder; thin identity headers rejected (`plexClientIdentityHeadersComplete`)
- Gate: baseline/CB → fabric eligible; main/high → ARM fallback (not product kill)
- q5 mailbox wire already at doorbell+0x828 (ABI #2); bit34 vacated

## true rc

All curl probes above: `true rc=0` with printed `http_code=`.
