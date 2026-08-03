# Parent — pair daemon with 540p fabric fit

## 1) Build `misterplexd` from

| Field | Value |
|-------|--------|
| **Branch** | `w-path-720p` |
| **Worktree** | `/home/flynnsbit/Projects/MisterPlex-wt-path` |
| **Minimum commit** | `8e62f61b` (*p720-path: ship 960x540 source tier…*) |
| **Recommended tip** | `70fd06e4` (or later on same branch) |
| **Must contain** | `plexTranscodeProfiles()` entries `540p` / `960x540` |

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
misterplexd: GEOM requested_pms=960x540 ... decode_target=960x540 content_tier=960x540 ...
```

Also expect resolve detail / URL side to carry `videoLevel=31` and `videoProfile=baseline` (ladder pin).

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

At 24 fps, 2000 kbps ≈ **10.4 kB/frame** average budget — same *class* as parent’s true-720 ~13.5 kB/frame content rate, not a geometry gate. Lab has **not** proven PMS always returns coded 960×540 at 2000 (ceiling trap still applies). Trust **measured** delivery (`GEOM` / ffprobe / `measured` tags), not the request alone.

`AUTO_LADDER_STEPDOWN=1` can lower bitrate on STARVED without changing WxH — if geometry is lost, raise `WEAK_BITRATE` or disable stepdown for the test; do not assume silent reject.

## Pairing checklist (parent)

1. RBF = w-nostub fit expecting **960×540** content window  
2. Daemon = `w-path-720p` ≥ `8e62f61b`  
3. Conf: `DECODE=960x540` + `OSD_CONTROL=off`  
4. Grep log: `requested_pms=960x540` and `source=conf/--decode`  
5. Then score glass — not before  
