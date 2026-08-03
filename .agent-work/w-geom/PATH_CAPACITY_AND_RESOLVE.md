# Path capacity vs 480p resolve — tip evidence + options

**Tip:** `w-geom-lane` (this commit). Independent of sibling `3fa5fab4` trust.

---

## 1) Resolve path — quoted tip (refute stale :338-339 floor)

### Decoder contract (HARD) — `plex_resolve.cpp:325-332`
```
videoCodec must be h264
audioCodec must be aac
h264Profile must be baseline
h264Level must not exceed 3.0
```
These are the FPGA/product decoder contracts. **Bitrate is not among them.**

### Former 2000 hard floor — GONE on tip (`:338-341`)
```
// Bitrate floors are NOT decoder contracts (see recommendedMinVideoBitrateKbps).
// A hard 2000 kbps reject forced PMS requests above slow links and silently
// fell the ladder back to 240p — parent-proven 480p drop root cause.
// Decoder contracts remain: h264 baseline + level ≤ 3.0 above.
```
**No** `if (maxVideoBitrateKbps < 2000) return fail`. Sibling claim confirmed by source + unit run.

### Profile table — `:163-167`
```
{"240p", p240.label, p240.weakBitrateKbps, 40, "baseline", 30},
{"480p", p480.label, p480.weakBitrateKbps, 60, "baseline", 30},
```
`p480.weakBitrateKbps` = `kPlex480pWeakBitrateKbps` = **2000** (`osd_menu.hpp:57`) — **default request**, not a validate fail.

### X-Plex headers — `:37-46` (httpGet identity) and `plexFfmpegHeaders` ~480-495
```
X-Plex-Client-Identifier: misterplex
X-Plex-Product: Plex Web
…
X-Plex-Client-Profile-Name: MiSTerPlex  (or weak.clientProfileName)
+ Capabilities / Profile-Extra when non-Chrome generic path
```

### What we **ask** PMS at 480p
| Field | Value | Source |
|-------|-------|--------|
| `videoResolution` | `624x480` | `plex480pCodedResolutionLabel()` |
| `maxVideoBitrate` | **2000** default, or `WEAK_BITRATE`, or capacity clamp | URL `buildUniversalTranscodeUrl` `:452-453` |
| profile/level | baseline / 30 | profile table + limitations |
| upperBound w/h | 624 / 480 | `plexClientProfileExtra` |

### Unit proof (host, true rc direct)
```
test_resolve: PASS 480p WEAK_BITRATE below recommended + link capacity clamp
true rc=0
```
`WEAK_BITRATE=900` → URL contains `maxVideoBitrate=900`, validates.

---

## 2) Geometry: ask 624×480, measure 624×350 — intentional letterbox

| Layer | Size | Role |
|-------|------|------|
| PMS request | 624×480 | coded ladder / upperBound |
| **measured** (ffmpeg Input banner) | **624×350** (rk=9 class) | actual delivery; often even-floor of 16:9@624 (`624×9/16=351→350`) — PMS, not ARM |
| DDR coded store | **624×480** fixed | `ddr_frame_layout.hpp:15-16`, synthesis |
| display crop | 618×480 | crop_right=6 |
| presented scanout | 640×480 | pillar 11+11 |

**Letterbox is intentional:** FORCE_SCALE / product vf pads delivery into coded 624×480  
(OUTPUT always **449280** B). Host gate: `g_624x350` → 449280×N, true rc=0.

`decode=624x480` = coded bank / DECODE tier.  
`measured=624x350` = delivered elementary stream.  
`delivery_verified=1` only after banner (`basis=measured`).

---

## 3) Parent capacity vs default request (arithmetic only)

| Quantity | Value | Tag |
|----------|------:|-----|
| Greedy goodput | 144136 B/s = **1.153 Mbit/s** | parent measured |
| p95 1s capacity est. | **1.292 Mbit/s** | parent measured |
| Default 480p request | **2000 kbit/s** | source default |
| Oversubscribe (goodput) | 2000/1153 ≈ **1.73×** | derived |
| Oversubscribe (p95) | 2000/1292 ≈ **1.55×** | derived |
| 85% of 1153 | **980 kbit/s** | example clamp if conf set |

**Defect shape:** default request can exceed path; hard fail is already removed.  
Remaining product gap: **default still 2000** until operator/sibling supplies capacity or WEAK_BITRATE.

---

## 4) Options for “what resolve does with the number” (no new magic default)

| Opt | Mechanism | Cost | When |
|-----|-----------|------|------|
| **A. Conf `WEAK_BITRATE`** | Operator sets quality target; already honored | Manual; quality trade explicit | Lab / known slow path |
| **B. Conf `LINK_CAPACITY_KBIT` + headroom** | **Measured** cap clamps `min(request, cap×pct/100)` | Needs valid greedy probe; quality may drop | After parent/sibling knee exists |
| **C. Tier table rungs** | 480p_hi/med/lo in profile table | Still needs empirical knee; multiplies OSD surface | After CBR ladder maps knee |
| **D. Runtime probe each play** | Measure before URL | Contaminated by fleet/PMS load; latency | Avoid as default |
| **E. Reactive `supply_class=STARVED` step-down** | `AUTO_LADDER_STEPDOWN` / recommended log | After user already sees judder | Safety net, not first choice |

**Shipped this tip:** **A + B + E**.  
- B applies **only when** `LINK_CAPACITY_KBIT>0` (unset = no clamp — **never invents** 1153).  
- Default headroom **85%** is a conf default for the *fraction*, not a baked path speed.  
- User chooses quality vs reliability by setting capacity and/or WEAK_BITRATE.

**Not done:** changing default `kPlex480pWeakBitrateKbps` to 1000 — that **is** swapping magic constants; rejected unless user decides.

### Contamination warning (parent)
Transcode evidence is invalid when Plex Transcoder is fleet-starved. Prefer direct-play  
or publish host load with any bitrate A/B. Pixels currently unscored (grabber lock lost).

---

## 5) Parent commands (device — agent does not run)

```sh
# After deploy daemon from this tip:

# A) Prove default still asks 2000 when capacity unset
# conf: no WEAK_BITRATE, no LINK_CAPACITY_KBIT, DECODE=624x480
grep -E 'maxVideoBitrate=|link_capacity|bitrate_below|GEOM requested' \
  /media/fat/misterplex_v2/misterplexd.log | tail -30
echo "true rc=$?"
# PASS shape: maxVideoBitrate=2000 (or PLAY … maxVideoBitrate=2000); no link_capacity_clamp

# B) Prove measured capacity clamp (parent number — not invented by daemon)
# conf: LINK_CAPACITY_KBIT=1153 LINK_CAPACITY_HEADROOM_PCT=85
# PASS shape: link_capacity_clamp … requested_kbps=2000 capacity_kbps=1153 applied_kbps=980
#           PLAY maxVideoBitrate=980
# PRE_REG: supply_class better than default-2000 on same path (if not transcoder-starved)
# Publish: host load + complete/speed from /transcode/sessions

# C) Geometry ledger (no pixels required)
grep -E 'measured_delivery=|SESSION_COLLAPSE_LEDGER|GEOM requested' \
  /media/fat/misterplex_v2/misterplexd.log | tail -40
echo "true rc=$?"
# PASS shape: requested 624x480; measured often 624x350; identity_skip=0 under FORCE_SCALE
```

### Host gates already green
| Gate | true rc |
|------|---------|
| test_resolve (incl. capacity clamp math) | 0 |
| test_force_scale_ffmpeg_out (g_624x350) | 0 |
