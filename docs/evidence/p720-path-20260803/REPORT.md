# w-path — 720p host path delivery (p720-path)

| Field | Value |
|---|---|
| **Lane** | w-path / todo `p720-path` |
| **Branch** | `w-path-720p` |
| **TS** | 2026-08-03 (lab local PMS) |
| **Scope** | Host path only — no MiSTer SSH/deploy/HDMI |
| **Asset** | rk=7 `MiSTerPlex Test 720p (2026)` native 1280×720 CB L3.0 SAR 1:1 |

---

## (a) Real PMS 720p delivery evidence

### Library metadata (rk7)

```text
Media: width=1280 height=720 aspectRatio=1.78 videoProfile=constrained baseline
       videoCodec=h264 videoResolution=720 container=mp4 videoFrameRate=24p
Stream: width=1280 height=720 level=30 profile=constrained baseline codec=h264
        frameRate=24.000 refFrames=1  (ffprobe SAR=1:1 DAR=16:9 bit_rate≈487599)
```

### Decision matrix (MiSTerPlex client profile, universal/decision)

| Request | Decision coded | Profile (decision XML) | Notes |
|---|---|---|---|
| `videoResolution=1280x720` maxBR=**4000** L31 | **1280×720** | constrained baseline | **HIT true 720p** |
| same maxBR=**3500** | **1280×720** | CB | measured gate |
| same maxBR=**3000** | **720×404** | CB | **NOT true 720p** |
| same maxBR=**2000** | **720×404** | CB | bitrate-starved |
| `videoResolution=624x480` maxBR=2000 | **624×350** | CB | same 16:9 ceiling trap |
| `directPlay=1` | **1280×720** Part | CB L30 | Direct play OK |
| rk6 (anamorphic 624×480) + 1280×720 ceiling | **852×480** | CB | PMS does **not** invent 720 from SD |

Quoted decision Media (post profile install, true 720p):

```xml
<Media ... videoProfile="constrained baseline" ... bitrate="3435" container="mpegts"
       height="720" videoCodec="h264" videoFrameRate="24p" videoResolution="720p"
       width="1280" selected="1">
```

Quoted decision Media (br=2000 — **negative**):

```xml
<Media ... height="404" ... videoResolution="SD" width="720" ...>
```

### Bitstream ffprobe (start.mp4 drained to file)

| Sample | width×height | profile | level | SAR |
|---|---|---|---|---|
| Source file / Direct Play | 1280×720 | Constrained Baseline | 30 | 1:1 |
| Transcode maxBR=4000 **before** profile fix | 1280×720 | **Main** | 31 | 1:1 |
| Transcode maxBR=4000 **after** MiSTerPlex.xml 1280×720/L31 install + PMS restart | 1280×720 | **Constrained Baseline** | 31 | 1:1 |
| Transcode maxBR=2000 | 720×404 | High (pre) / short | — | — |
| rk6 @624×480 product (regression) | 624×350 | Constrained Baseline | 31 | — |

**Pre-register misses:** P4 predicted L30 might block 720 — **MISS** (decision OK at L30/L31/L40).  
P1 HIT. P2 HIT. P3 HIT (624×350). Bitrate gate at 3500 was **not** pre-registered precisely — measured 3000→404h / 3500→720h.

Artifacts: `docs/evidence/p720-path-20260803/decision_*.xml`, `probe_*.txt`, `cpu_*.txt`.

---

## (b) Cheapest genuine 720p route

| Route | Coded | ARM scale | Re-encode | H.264 class | Verdict |
|---|---|---|---|---|---|
| **Direct Play native 720p H.264 CB** | 1280×720 | identity_skip | none | CB L30 ref=1 | **CHEAPEST** |
| Universal 1280×720 maxBR≥3500 + fixed profile | 1280×720 | identity_skip if verified | PMS pays | CB L31 after profile | Viable path tier |
| Universal 1280×720 maxBR≤3000 | 720×404 | **must scale** | yes | wrong geometry | **FAIL true-720** |
| Universal on SD source + 720 ceiling | ≤852×480 | upscale | yes | — | **Not genuine 720p** |

**Recommendation:** Prefer `preferDirectH264` / Direct Play for native 720p baseline assets.  
For non-DP titles, request **720p ladder @ maxVideoBitrate=4000** (floor measured 3500) and **require measured coded 1280×720** before identity_skip. Never trust `videoResolution=` alone.

---

## (c) Host-side implementation

| Area | Change |
|---|---|
| `osd_menu.hpp` | `contentResolutionFor720p()`, `kPlex720pWeakBitrateKbps=4000`, `Path720p` policy; `DECODE=1280x720` maps to 720p ladder; OSD tier 11 stays safe 480p; **`preferDirectH264ForContent`** — Path720p defaults DP when conf unset |
| `ddr_frame_layout.hpp` | `kPlex720pCodedWidth/Height`, `kPlex720pYuv420pBytes=1382400`; **DDR accept still rejects 720** (w-mem) |
| `plex_resolve.{hpp,cpp}` | Profile `720p` → 1280x720 / 4000 kbps / q70 / baseline / L31; validate allows exact path-720; bitrate step ladder includes 4000/3500 |
| `pms_delivery_geom.hpp` | `isGenuine720pDelivery`, `pmsBitrateLikelyTrue720p` (≥3500); **`deliveryBasisForResolve`** → `direct_play_part` when !transcoded |
| `yuv420p_chroma_health.hpp` | `deliveryGeometryVerifiedFromBasis` accepts **`measured` + `direct_play_part`** (not library_media) |
| `main.cpp` | `PREFER_DIRECT_H264` conf; per-play preferDirect via content policy; DP sets verified basis at plan time |
| `coded_size.hpp` | `parseCodedSizeString("1280x720")` OK for path tier without DDR accept |
| `assets/plex-profiles/MiSTerPlex.xml` | Caps 1280×720, level 31, encode flags baseline L3.1 — **required** so start.mp4 is CB not Main |
| `misterplex.conf.example` | Documents PREFER_DIRECT_H264 + Path720p default |
| vf | Reuses existing `SkipIdentity` / crop+pad — no parallel path; **Always+exact+DP verified → identity_skip** (ARM scale filter gone) |

480p path unchanged in API; unit tests still green for 480p.

### ARM-evac design choice (parent directive)

Chose **“ARM out of the scale loop entirely”** over “cheaper ARM scale”:
- Path720p + eligible H.264 → **Direct Play Part** by default (PMS transcoder out).
- DP Part sample WxH is **`direct_play_part`** (plan-time verified) so FORCE_SCALE product path takes **`force_exact_identity`**, not FOAR.
- Universal still unverified until measured (cannot rebuild vf mid-session) — bitrate floor + genuine-delivery gates keep the 404 trap from claiming identity.

---

## (d) ARM cost vs 41.7 ms @24 fps

### ARM milliseconds this change removes (honest)

| Claim | Evidence | ms/f |
|---|---|---|
| identity_skip ⇒ scale filter **absent** | `buildFfmpegVideoFilter` Always+exact+`direct_play_part` → `identity_skip=1`, `scale_applied=0` (unit) | **scale bucket = 0 by construction** |
| Archived ARM scaleΔ @624×480 FOAR | task brief / p720-scope-arm | **2.954 ms/f** (class of work when FOAR required) |
| Host FOAR same-size vs identity (240f CB 720p blip) | `probe_id720` / `probe_foar720` child_cpu | id **2.075** ms/f · foar **2.180** ms/f · Δ **+0.105** (x86 only) |
| Host 404→720 upscale trap vs identity | `probe_up404` | **4.667** ms/f · Δ **+2.59** vs id (x86 only) |
| **Device dual-A9 ms/f removed by DP identity** | no MiSTer SSH | **unknown** — parent: profile DP identity vs FORCE FOAR same asset |

### Parent device decode — REAL content (2026-08-03)

Source: parent `/tmp/misterplex-parent-720p-decode-verdict.txt` (device `ffmpeg_cpu_probe`, 300f/arm, CB ref=1 bframes=0 cabac=0 @24fps; re-encode of true-HD PromoScoreable — **not** synthetic blip).

| Arm | wall ms/f | fps ceiling |
|---|---:|---:|
| 1280×720 @4000k default threads | **41.073** | 24.35 |
| 1280×720 @4000k threads=1 | 52.158 | 19.17 |
| 624×480 @1800k default threads | 15.969 | 62.62 |

- Budget 41.667 ms @24 fps → decode alone **98.6%** (margin **0.59 ms / 1.4%**).
- Discard synthetic 1080p blip 32.4 ms/f — not representative.
- 480p CPU-time 22.02 vs archived 21.562 (2.1%) — harness OK.
- Decode wall scales **0.836× linear-in-pixels** → bitrate/tier is a first-class lever (path 4000 / floor 3500 geometry gate stands).

**Invalidated by this measurement:** any plan that leaves present/pipe/scale on ARM at 720p; host “~70–120% if scale skipped” as a ship path without fabric offload.

### Host `ffmpeg_cpu_probe` (x86 lab, **not** dual-A9)

Earlier 120f series:

| Label | child_cpu_s | ms/f CPU | notes |
|---|---:|---:|---|
| 720_identity_fps | 0.277 | **2.31** | fps only, already 1280×720 |
| 720_full_scale_pad | 0.303 | 2.52 | near-identity scale+pad |
| 720_scale_from_404 | 0.677 | **5.64** | forced short→720 scale |
| 480_identity | 0.116 | 0.97 | same host baseline |

ARM-evac addendum 240f / 10s CB 3500k:

| Label | child_cpu_s | ms/f CPU |
|---|---:|---:|
| id720 (null vf) | 0.498 | 2.075 | `probe_id720_summary.txt` |
| foar720 (FOAR 1280→1280) | 0.523 | 2.180 | `probe_foar720_summary.txt` |
| up404 (scale 720x404 then FOAR 720) | 1.120 | 4.667 | `probe_up404_summary.txt` |

### Fit verdict (post parent 41.073 ms/f)

- **Decode alone ≈ full 24 fps budget.** Path must deliver genuine 1280×720 + identity_skip so ARM spends ~0 on scale; fabric must own present/pipe/overlay.
- **Scale evacuation on true DP 720:** product path identity when Part samples==bank — **necessary**, not sufficient.
- Non-decode ARM residual with zero fabric offload: parent ~57 ms/f projection + 41 ms decode → **~10 fps** — matches prior bucket-lift class; **does not ship**.
- DDR push @24 fps: 33.2 MB/s (1 382 400 B × 24) — w-mem.

---

## (e) Red-before-green tests (true rc)

```text
./build/test_resolve              true_rc=0   GREEN_PATH_720p url+genuine_delivery+bitrate_gate
./build/test_ffmpeg_vf            true_rc=0   GREEN_PATH_720p_VF + DP identity + unverified NEG
./build/test_osd_menu             true_rc=0   Path720p + preferDirectH264ForContent matrix
./build/test_yuv420p_chroma_480p  true_rc=0   direct_play_part verified
./build/test_coded_size_adopt     true_rc=0
ddrFrameStoreAcceptsResolution(1280,720)=0  (invariant kept for w-mem)
```

Negative cases locked:
- `isGenuine720pDelivery(720,404)==false`
- `isGenuine720pDelivery(624,350)==false`
- vf: 720×404 into coded 1280×720 **must scale**, not identity_skip
- vf: **unverified** exact 1280×720 claim **must not** identity_skip (FOAR)
- `library_media` / `transcode_request` still not verified
- `preferDirectH264ForContent(true,false,…,Path720p)==false` (explicit off)
- `pmsBitrateLikelyTrue720p(2000)==false`

---

## (f) Coordination + unknowns

### w-mem (DDR ABI)
- Path requests **1280×720 / 1 382 400 B/frame**; current `kDdrFrameStoreMax=640×480`, bank stride 512 KiB — **reject**.
- Contract: path may adopt DECODE=1280×720 for PMS/vf; **present must stay refused** until remap.
- Doorbell/bank layout for 720p is w-mem exclusive.

### w-scaler (fabric content window)
- True 720p content window is 1280×720 square SAR when delivery genuine.
- 720×404 and 624×350 are **not** 720p — fabric must not be told “720p” from request alone.
- Widescreen OSD tier 10 remains **16:9-framed 480p canvas**, not path-720p.

### Unknowns
1. Dual-A9 ms/f for genuine 1280×720 CB identity_skip (device profile).
2. Whether Main-profile leak returns if Profiles/MiSTerPlex.xml missing on a PMS.
3. Bitrate gate on non-rk7 titles (only rk7 ladder scanned).
4. OSD bit for 720p (reserved 11 still 480p) — needs RBF/menu ABI.
5. Present path end-to-end once w-mem banks exist.

---

## Parent verify commands (no agent device)

```bash
# Units
make $PWD/build/test_resolve $PWD/build/test_ffmpeg_vf $PWD/build/test_osd_menu
./build/test_resolve; echo true_rc=$?
./build/test_ffmpeg_vf; echo true_rc=$?

# Install profile on lab PMS (once)
docker cp assets/plex-profiles/MiSTerPlex.xml \
  plex:"/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml"
docker restart plex

# ARM profile on device (parent only)
PROFILE_SAMPLE=... WIDTH=1280 HEIGHT=720 FRAMES=300 \
  scripts/run_arm_decode_profile.sh
```

---

## Lab PMS re-proof (daemon path, unique session) — parent 400 RCA

Parent hand requests returned HTTP 400 at both 720 and 480 — **request construction**, not PMS refusing 720.
Daemon `buildUniversalTranscodeUrl` + full Chrome/MiSTerPlex headers + **unique session** → **HTTP 200**.

See `LAB_PMS_720_DAEMON_PATH.md` for the coded-size matrix and bitrate pin (product **4000**, geometry min **3500**).

OSD product: `OSD_TIER11_720P` default **0**; when 1, O[5:4]=11 → Path720p.
