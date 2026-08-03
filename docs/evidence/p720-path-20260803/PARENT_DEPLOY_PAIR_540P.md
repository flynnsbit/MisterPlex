# Parent — pair daemon with 540p fabric fit

## 1) Build `misterplexd` from

| Field | Value |
|-------|--------|
| **Branch** | `w-path-720p` |
| **Worktree** | `/home/flynnsbit/Projects/MisterPlex-wt-path` |
| **Minimum commit** | `8e62f61b` (*p720-path: ship 960x540 source tier…*) |
| **Recommended tip** | branch tip on `w-path-720p` (includes PMS 540 delivery evidence) |
| **Must contain** | `plexTranscodeProfiles()` entries `540p` / `960x540` |
| **Delivered geometry doc** | `docs/evidence/p720-path-20260803/PMS_540_DELIVERED_GEOMETRY.md` |

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-path
git rev-parse HEAD   # expect ≥ 8e62f61b on w-path-720p
make arm-plexd
# artifact:
ls -l build/arm/misterplexd
./scripts/deploy_misterplexd.sh build/arm/misterplexd
```

RBF and daemon are **independent deploys**. Fit RBF without this daemon → PMS may send 240/480 into a 960×540 fabric (false D2/D3).

## 2) How the tier is selected at runtime

**Product source of truth for each play** (`main.cpp`):

```
contentResolutionForNextPlay():
  if osdApplyActive() → contentResolutionFromOsdWord(O[5:4])
  else               → contentResolutionFromCodedSize(DECODE / --decode)
→ weakForContentResolution() → PMS URL videoResolution / maxVideoBitrate / videoLevel
```

### Path A — conf (recommended for this PLAYING test)

`/media/fat/misterplex/misterplex.conf`:

```ini
DECODE=960x540
# optional aliases (same ladder entry):
# TRANSCODE_PROFILE=540p
# WEAK_RES=960x540

# Bitrate: default weak is 2000 if unset
# WEAK_BITRATE=2000

# Frame-rate cap (540p defaults to 24 via Client-Profile-Extra; conf overrides):
# WEAK_MAX_FRAME_RATE=24
# WEAK_MAX_FRAME_RATE=0   # disable Extra cap (29.97 pass-through — serial FAIL budget)

# CRITICAL: if OSD apply is LIVE, O[5:4] overrides DECODE and has NO 540p slot
# (00=240p, 01=480p, 10=ws480, 11=720 only if OSD_TIER11_720P=1 else 480p).
# Force conf tier for the paired fit test:
OSD_CONTROL=off
```

CLI equivalent: `misterplexd --decode 960x540` (still set `OSD_CONTROL=off` if OSD would apply).

### Path B — OSD menu

**There is no O[5:4] value for 540p yet.** Do not rely on F12 Content tier for this fit.

### Device verification (grep these lines after cast/play)

```bash
# on device log (path may be misterplexd.log / journal)
grep -E 'DECODE adopted|content resolution=|GEOM requested_pms=|resolved ' \
  /media/fat/misterplex/misterplexd.log | tail -20
```

**PASS pairing evidence (all must match):**

```text
misterplexd: DECODE adopted coded 960x540 from conf ...
misterplexd: content resolution=960x540 source=conf/--decode ... weak=960x540 bitrate=2000 ...
misterplexd: GEOM requested_pms=960x540 ... decode_target=960x540 content_tier=960x540 ... max_video_frame_rate=24 ...
```

**Also require** (post rd-duck #3 fix): decode_target / coded bank is **960x540**, not
`624x480` (old always-canvas bug) and not `1280x720` (DE canvas leak). FFmpeg/publish
payload must be **777600** B.

Also expect resolve detail / URL side to carry `videoLevel=31` and `videoProfile=baseline` (ladder pin).

**Frame rate (29.97 library):** default 540p sends frame-rate-only
`X-Plex-Client-Profile-Extra` upperBound `video.frameRate=24` (measured: PMS delivers
`r_frame_rate=24/1` on 29.97 sources). Grep `max_video_frame_rate=24`. Without the
cap, PMS **passes through 30000/1001** and serial budget is FAIL (−1.17 ms). See
`FPS_RESULTS_20260803.md`.

**FAIL / wrong pair:**

```text
content resolution=320x240   or  624x480
source=OSD O[4]
GEOM requested_pms=320x240   or  624x480
```

If `source=OSD O[4]` during the test → conf DECODE was ignored; set `OSD_CONTROL=off` and replay.

## 3) Bitrate for 540p

| Constant | Value | Role |
|----------|------:|------|
| `kPlex540pWeakBitrateKbps` | **2000** | Default `maxVideoBitrate` quality heuristic |
| Geometry floor like 720p’s 3100? | **No** | Comment: “quality default only — NOT a PMS geometry floor; prove coded WxH on device” |
| Hard reject if below recommended? | **No** | `weakLadderBitrateBelowRecommended` → **WARN only**; explicit `WEAK_BITRATE` wins |
| H.264 level requested | **31** | `kPlex540pH264Level` / MaxFS (960×540) |
| Profile | **baseline** | Always pinned in URL |

At 24 fps, 2000 kbps ≈ **10.4 kB/frame** average budget. **Measured on local PMS
(2026-08-03, daemon URL, HD 16:9 rk2/rk7):** maxBR=1500 → **720×404**; maxBR≥**2000**
→ **display=coded ffprobe 960×540 SAR 1:1**, CB L31, I420 **777600 B**. SPS MB height
is 544 with bottom crop 4; ARM publishes **540** after ffmpeg crop — bank = 777600,
not 783360. 4:3 HD (rk83) → 720×540, never full width. SD sources cannot reach 540p.

`AUTO_LADDER_STEPDOWN=1` can lower bitrate on STARVED and may fall through the 2000
knee → 720×404. Disable stepdown or floor `WEAK_BITRATE` for the PLAYING test.

**PLAYING hard preconditions (delivery):**

1. Grep request `GEOM requested_pms=960x540` (this card §2).
2. ffprobe delivered `width=height=coded_*=960x540` (`PMS_540_DELIVERED_GEOMETRY.md` §4).
3. w-mem Option-C / present geometry accepts **960×540 / 777600** (host
   `ddrFrameGeometryForFpgaPresent` still returns **480p** until paired flip —
   do not score glass until present path matches fabric).

## Pairing checklist (parent)

1. RBF = w-nostub fit expecting **960×540** content window  
2. Daemon = `w-path-720p` ≥ `8e62f61b`  
3. Conf: `DECODE=960x540` + `OSD_CONTROL=off`  
4. Grep log: `requested_pms=960x540` and `source=conf/--decode`  
5. Then score glass — not before  
