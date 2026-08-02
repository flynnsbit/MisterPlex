# Resolution-preserve knee + decode-cost ladder (host design)

**Parent fact (quoted):** requested `maxVideoBitrate` changes **delivered** geometry:

| request | delivered | n |
|--------:|-----------|--:|
| 397 | **312×240** | 40 |
| 2000 | **624×480** | 39 |
| 397 (A') | **312×240** | 40 |

Source ffprobe was truly 624×480 @ ~397 kbit — so 312×240 is **PMS downscale**, not
the file. **Standing rule:** every arm records **delivered** WxH; never pool arms
with different delivered geometry.

This lane does **not** edit `plex_resolve` floor (w-cpu-1 owns
`kPlexResPreserveRefKbps=2000` PROVISIONAL).

---

## 1. Decode-cost ladder (fixed coded geom + near-fixed source kbit)

**Not a bitrate ladder.** All arms below are **source-coded 624×480 @ 24/1**,
video target **~800 kbit** CBR (total PMS ~920), CB unless noted. Compare only
when **delivered** geom matches (expect 624×480 only if request is above knee).

### Encoder settings (precise)

| rk | key | profile | level | bf | refs (SPS) | cabac | deblock | slices | keyint | content | product_legal |
|---:|-----|---------|------:|---:|-----------:|------:|---------|-------:|-------:|---------|:-------------:|
| **115** | cb_ref1_cavlc | Constrained Baseline | 30 | 0 | **1** | 0 | 1:0:0 | 1 | 48 | BBB | YES |
| **116** | cb_ref3_cavlc | CB | 30 | 0 | **3** | 0 | 1:0:0 | 1 | 48 | BBB | YES |
| **117** | cb_ref5_cavlc | CB | 30 | 0 | **5** | 0 | 1:0:0 | 1 | 48 | BBB | YES |
| **119** | main_bf2_cavlc | Main | 30 | **2** | **4** (meas) | 0 | 1:0:0 | 1 | 48 | BBB | NO |
| **118** | high_cabac_ref1 | High | 30 | 0 | 1 | **1** | 1:0:0 | 1 | 48 | BBB | NO |
| **112** | cb_deblock_off | CB | 30 | 0 | 1 | 0 | **0:0:0** | 1 | 48 | BBB | YES |
| **113** | cb_deblock_strong | CB | 30 | 0 | 1 | 0 | **1:-3:-3** | 1 | 48 | BBB | YES |
| **114** | cb_noise_dense | CB | 30 | 0 | 1 | 0 | 1:0:0 | 1 | 48 | noise | YES |
| **122** | cb_slices4 | CB | 30 | 0 | 1 | 0 | 1:0:0 | **4** | 48 | BBB | YES |
| **123** | cb_slices8 | CB | 30 | 0 | 1 | 0 | 1:0:0 | **8** | 48 | BBB | YES |
| **120** | cb_gop24 | CB | 30 | 0 | 1 | 0 | 1:0:0 | 1 | **24** | BBB | YES |
| **121** | cb_gop240 | CB | 30 | 0 | 1 | 0 | 1:0:0 | 1 | **240** | BBB | YES |

x264-params pattern (product CB arms):

```text
cabac=0:no-cabac=1:ref=N:bframes=0:keyint=K:min-keyint=K/2:scenecut=0:level=30:
vbv-maxrate=800:vbv-bufsize=1600:slices=S
-profile:v baseline -level:v 3.0 -bf 0 -pix_fmt yuv420p
-b:v 800k -minrate 800k -maxrate 800k -r 24
-c:a aac -b:a 128k -ar 48000 -ac 2
-vf scale=624:480:flags=bicubic,setsar=1/1,fps=24
```

**Cast rule for decode-cost:** set request `maxVideoBitrate` **at or above** the
res-preserve knee (once known; until then use **2000** which parent already saw
deliver 624×480). **VOID** any arm whose delivered geom ≠ 624×480.

**Pre-reg (within-run / relative to rk115 at same delivered geom):**

| comparison | if true |
|------------|---------|
| ref5 ≪ ref1 supply or pfps | DPB/MC bound |
| slices8 ≪ slices1 | slice/thread parse cost |
| gop24 vs gop240 diverge | IDR frequency / seek refresh cost |
| noise ≪ BBB ref1 | residual density |
| high_cabac fails only STREAM=1 | entropy/recon |
| main_bf2 fails only STREAM=1 | B-frame path |

Session-mean A/B is retired (~25% intermittency). Use within-run instrument.

PMS `frameRate=None`, `videoFrameRate=24p` — asset truth **24/1**.

---

## 2. Calibrate LOWEST request bitrate that still delivers 624×480

### Assets (source fixed; you vary REQUEST)

| rk | title key | coded | src total br (PMS) | role |
|---:|-----------|------:|-------------------:|------|
| **130** | ResKnee src400k | 624×480 | 524 | low source (like rk36 class) |
| **131** | ResKnee src800k | 624×480 | 920 | mid |
| **126** | ResKnee src1200k | 624×480 | 1311 | mid-high |
| **127** | ResKnee src1600k | 624×480 | 1704 | |
| **128** | ResKnee src2000k | 624×480 | 2096 | ≈ old floor |
| **129** | ResKnee src2500k | 624×480 | 2584 | above floor |
| **124** | ResKnee 320×240 src400k | **320×240** | 531 | native-240 control |
| **125** | ResKnee 624×352 src800k | **624×352** | 924 | non-bank |
| **111** | DP-Control 400k | 624×480 | 527 | alternate low source |

All ResKnee: CB L30, B=0, ref1, AAC48k stereo, SAR1:1, **90 s**, 24/1.  
Generator: `scripts/gen_respreserve_knee_assets.py`.

Also reusable: rk36 (450), rk40 (848), rk34 (1247), rk35 (1843), rk30 (2621).

### Phase A — binary search on ONE asset (primary: **rk130** src400k)

**Why rk130:** matches the confounded class (low source, 624×480 file) where
request 397 → 312×240 was seen.

**Anchors already measured (parent):** R=397 → 312×240; R=2000 → 624×480.

**Metric per cast (first 10–20 s enough):** delivered WxH from ffmpeg banner /
`MEASURED_DELIVERY` / GEOM `measured=`. Record request R, source rk, delivered.

**Binary search (log₂ band):**

```text
lo = 397   # known DOWN
hi = 2000  # known FULL
while hi - lo > 100:          # ~100 kbit resolution
    mid = (lo + hi) // 2
    cast rk130 with maxVideoBitrate=mid for ≥15 s wall
    if delivered height >= 480 and width >= 624:  # FULL
        hi = mid
    else:
        lo = mid
knee_hat = hi   # lowest tested R that still FULL
```

| step | approx mid | casts |
|------|------------|------:|
| 1 | 1198 | 1 |
| 2 | ~800 or ~1600 | 1 |
| 3 | | 1 |
| 4 | | 1 |
| confirm A' at knee_hat | | 1 |
| confirm A' at knee_hat−100 | | 1 |
| **Total Phase A** | | **6–7** |

**Wall time:** ~20–40 s useful + cast overhead → budget **~8–12 min** device if
link OK; abort arm if no GEOM in 30 s (unstable link = NO-DATA, not 240).

**Pre-reg Phase A (before measure):**

| ID | prediction |
|----|------------|
| K1 | Exists finite knee K ∈ (397, 2000] on rk130 |
| K2 | K is **not** exactly 2000 only — expect K closer to mid band if PMS uses continuous ladder |
| K3 | A/B/A' at K and K−100 flips FULL↔DOWN (deterministic given same host load) |
| K4 | If K3 fails (same R, mixed geom) → knee **unstable**; stop and report host/PMS load (do not fit floor) |

**Miss publishing:** if K=2000 only (no mid FULL), say so — floor cannot drop.
If K≤500, PROVISIONAL 2000 is very conservative.

**Maps to w-cpu-1 formula:** for 624×480,
`floor = ceil(624*480 * kRef / (624*480)) = kRef`.
Measured K is the empirical `kPlexResPreserveRefKbps` **for this PMS+profile**,
not a guess.

### Phase B — is the knee ASSET or REQUEST? (after K known)

**Fixed request, vary source** (3–4 casts):

| cast | asset | request R | pre-reg if REQUEST-only | pre-reg if ASSET term |
|-----:|-------|----------:|-------------------------|------------------------|
| B1 | rk130 src400 | **K** | FULL 624×480 | FULL or boundary |
| B2 | rk130 src400 | **K−150** | DOWN (312×240 class) | DOWN |
| B3 | rk129 src2500 | **K** | FULL (same as B1) | may FULL easier |
| B4 | rk129 src2500 | **K−150** | DOWN (same as B2) | may still FULL |
| B5 | rk128 src2000 | **K−150** | DOWN | maybe FULL |
| B6 | rk124 320×240 | **2000** | stays ≤320×240 (no upscale) | same |

**Decision rule (pre-registered):**

```text
Let G(asset, R) = delivered height class {FULL480, DOWN240, OTHER}

REQUEST-only knee:
  G(rk130, K)=FULL480 AND G(rk129, K)=FULL480
  G(rk130, K-150)=DOWN240 AND G(rk129, K-150)=DOWN240
  → global kRef = K is OK; no source term.

ASSET term required:
  exists R0 such that G(rk130, R0)=DOWN240 AND G(rk129, R0)=FULL480
  (high source keeps FULL at request that downscales low source)
  → floor needs source bitrate and/or source coded pixels term.
  Publish: do not ship single constant without source factor.

SOURCE-only (degenerate):
  G independent of R for R in {K-150, K, 2000} but depends on asset
  → unexpected given parent A/B/A'; re-check instrumentation.
```

**Cast cost Phase B:** **6** short casts (B1–B6).  
**Optional B7:** rk125 @ R=K — expect 624×352 not 480 (source-limited height).

**Grand total calib:** Phase A 6–7 + Phase B 6 ≈ **12–13 short casts**.  
Not 5 arms × 6 session replicates. Geometry settles in seconds.

### What NOT to do

- Do not pool supply_ratio across arms with different delivered geom.
- Do not treat source kbit ladder under **universal** as decode-cost.
- Do not claim DP from eligibility alone — quote `transcode=` / Part.

---

## 3. rk30 soak (25% event rate)

Asset rk30: Real BBB GlassAV 624×480, ~2617 kbit total, **1200 s**, 24/1, CB.

Model: independent **~200 s** blocks, p(degraded)≈0.25.

| power for ≥1 degraded block | blocks k | wall |
|-----------------------------|----------|------|
| 80% | 6 | **~1200 s** (one full play) |
| 95% | 11 | **~2200 s** (two plays) |

**Protocol:** `docs/RK30_REAL_SOAK_PROTOCOL.md`  
Must hold **delivered 624×480** entire time (request ≥K) and DP if scoring
link/decode without transcoder confound.  
Block labels DEGRADED/HEALTHY; within-run instrument; no session A/B.

**Pre-reg soak:**

| ID | prediction |
|----|------------|
| S1 | With request≥K and DP: measured stays 624×480 |
| S2 | Overall supply may LINK_STARVE (2.6 Mbit > ~1.15 path) — publish, not hide |
| S3 | If universal at 2000: transcoder confound returns; VOID for clean decode |
| S4 | \(\hat p\) descriptive; one clean 1200 s ≠ “no intermittency” at 95% |

---

## 4. Generators / refresh

```bash
python3 scripts/gen_respreserve_knee_assets.py --duration 90 --copy-media
python3 scripts/gen_decode_load_ladder.py --duration 180 --dp-duration 300 --copy-media
TOK=$(cat /tmp/local_tok.txt)
curl -sS -o /dev/null -w 'refresh_http=%{http_code}\n' \
  "http://192.168.1.24:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
echo "refresh true rc=$?"
```

rks JSON: `docs/respreserve_knee_rks.json`
