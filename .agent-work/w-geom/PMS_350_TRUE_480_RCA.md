# PMS delivers 624×350 — proven RCA + true-480 options

**Branch tip:** see git. **Lane:** w-geom. Host-only; parent owns device.

## 0) Kill the 1.371 desync model (parent correction)

Session telemetry:

```
MEASURED_DELIVERY_FINAL 624x350 producer_bytes=327600 reader_bytes=449280
identity_skip=0 desync_risk=0
```

`pipeDesyncRisk` (`ffmpeg_vf.hpp`) returns `identity_skip` only after size mismatch.
With `scale_mode=always` / `identity_skip=0`, the scaler bridges to **449280** reader
bytes — **desync model inapplicable**. Do not fit R/S=1.371 to archived TREK24 N=2
captures unless that capture’s **own** log shows `identity_skip=1`.

Unit: `test_yuv420p_chroma_480p` asserts `!pipeDesyncRisk(327600,449280,false)`.

---

## 1) Why PMS delivers 350 rows — **PROVEN** (not hypothesis)

### Library metadata (PMS `GET /library/metadata/6`, 200)

| Field | Value |
|-------|--------|
| Media width×height | **624×480** |
| Media aspectRatio | **1.78** |
| Stream codec | h264 constrained baseline L3.0 ref=1 |
| Stream pixelAspectRatio | **160:117** |
| title | MiSTerPlex Test 480p (2026) |

### DAR arithmetic (exact)

```
DAR = (624/480) * (160/117) = 99840/56160 = 16/9 exactly
```

### Square-pixel fit into ceiling 624×480

```
height = floor(624 / (16/9)) = floor(351) = 351 → even-floor 350
→ delivered 624×350
```

Host helper: `pmsSquarePixelFitInCeiling(16/9, 624, 480) → 624×350`.

### PMS universal/decision matrix (lab PMS, MiSTerPlex profile, rk=6)

| Request `videoResolution` | Decision coded | Pre-register | Result |
|---------------------------|----------------|--------------|--------|
| 624×480 (product) | **624×350** | 624×350 | **HIT** |
| 640×480 | **640×360** | 640×360 | **HIT** |
| +width/height=624/480 | 624×350 | 624×350 | **HIT** |
| 853×480 | **852×480** | unknown→480h | true 480 rows, **w>624 bank** |
| 720×480 | 720×404 | — | mid |
| directPlay=1 | **624×480** + SAR 160:117 | direct OK | **mdeDecision Direct play OK** |

Artifacts: `.agent-work/w-geom/rk6_metadata.xml`, `rk6_decision.xml`, `rk6_decision_direct.xml`.

**Mechanism:** PMS aspect-preserving **square-pixel** transcode honours **display** aspect (16:9 from SAR), not storage 624×480. `videoResolution` is a **ceiling**.

---

## 2) Can we make PMS deliver true 480 rows?

| Path | 480 unique rows? | Fits DDR coded 624? | Notes |
|------|------------------|---------------------|--------|
| Universal + `videoResolution=624x480` | **No** (~350) | yes width | product STREAM=0 cast |
| Universal + `640x480` | No (~360) | yes | still short vertically |
| Universal + `853x480` | **Yes** (~852×480) | **NO** (852>624) | needs RBF wider store |
| Exact pin via query | **No param found** | — | no `&width=`/`&height=` in our URL; extras ignored |
| **Direct play** Part (H.264) | **Yes 624×480 coded** | yes | anamorphic SAR 160:117; STREAM preferDirect / directPlay=1 decision OK |
| Force square 16:9 @480h in 624w | **Impossible** | — | needs w≈853 |

`buildUniversalTranscodeUrl` hardcodes `directPlay=0&directStream=0` and only sends `videoResolution=` — **no exact geometry pin**.

STREAM=1 `preferDirectH264` uses Part URL (keeps 624×480 samples). STREAM=0 always universal → 350 for this DAR class.

---

## 3) Honest product statement

> **The “480p” tier requests a 624×480 ceiling. For 16:9 display-aspect content (including anamorphic 624×480 masters with SAR≠1:1), PMS universal delivers ~624×350 square-pixel samples (~73% of requested vertical resolution). The daemon upscales to the 624×480 DDR bank. That is why 480p can “not look like 480p.”**  
> True square-pixel 480 rows at 16:9 need ~853 width — outside the synthesis-fixed 624 bank without an RBF change. Direct-play of compatible H.264 keeps 480 coded rows but remains anamorphic unless display applies SAR.

Vertical detail fraction: `350/480 ≈ 0.729`. Stretch to bank: `480/350 ≈ 1.371×` (presentation upscale — **not** a desync ratio when identity_skip=0).

---

## 4) delivery_verified + B5 (status)

- Play-time GEOM `delivery_verified=0` until ffmpeg measured banner — **correct**.
- After banner: `delivery_verified=1` + loud `DELIVERY_MISMATCH` + `vertical_detail_frac=`.
- B5 arm teardown already calls `rawPipeByteAligned` / `rawPipeDesynced` / `PIPE_DESYNC=1` (rd-review “unit only” brief stale).

GEOM now also logs: `media_ar=` `sar=` `content_dar=` `predicted_square_fit=` `square_px_w_at_coded_h=` `note=videoResolution_is_ceiling_not_exact`.

---

## 5) Parent device checks

```bash
# After deploy tip — RK6 cast, line-mark log first
rg -n 'GEOM |MEASURED_DELIVERY|DELIVERY_MISMATCH|vertical_detail|predicted_square|identity_skip' \
  /media/fat/misterplex/misterplexd.log | tail -50
```

**Pass shape:**  
`GEOM ... sar=160:117 content_dar=1.7778 predicted_square_fit=624x350 square_px_w_at_coded_h=854`  
`MEASURED_DELIVERY ...624x350... delivery_verified=1 decode_target_match=0 identity_skip=0`  
`ERROR DELIVERY_MISMATCH ... vertical_detail_frac=0.72... force_scale_protects=1`

Optional decision probe (host or device with token):

```bash
# Expect width=624 height=350 in decision XML for videoResolution=624x480
curl -sS -g "http://PMS:32400/video/:/transcode/universal/decision?...&videoResolution=624x480&directPlay=0&..." 
```

---

## 6) Options for the user (no magic bitrate)

1. **Accept** 350→480 upscale; advertise tier honestly as “480p ceiling / ~350 delivered for 16:9”.
2. **Direct-play** path when source is already Baseline H.264 (480 coded rows; handle SAR in vf or accept anamorphic).
3. **RBF** wider coded store (≥854) if square-pixel full-height 16:9 is required — exclusive fit, not justified until product chooses.
4. **Do not** treat 1.371 as desync without identity_skip=1 evidence.
