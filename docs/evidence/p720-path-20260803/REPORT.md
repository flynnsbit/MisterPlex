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

**Recommendation:** Prefer `preferDirectH264` / Direct Play of **~1500k native 720p CB** assets (parent decode 32.427 ms/f).  
For non-DP titles, request **720p ladder @ maxVideoBitrate=3500** (lab geometry floor; product weak pin) and **require measured coded 1280×720** before identity_skip. Never trust `videoResolution=` alone. **Never set universal maxBR=1500** expecting true 720 — lab returns **720×404**.

See `BITRATE_1500_VS_GEOMETRY.md`.

---

## (c) Host-side implementation

| Area | Change |
|---|---|
| `osd_menu.hpp` | `contentResolutionFor720p()`, dual pin `kPlex720pDecodeOptimalBitrateKbps=1500` + `kPlex720pWeakBitrateKbps=3100`, `Path720p`; `DECODE=1280x720` maps to 720p ladder; OSD tier 11 behind `OSD_TIER11_720P` default 0; **`preferDirectH264ForContent`** — Path720p defaults DP when conf unset |
| `ddr_frame_layout.hpp` | `kPlex720pCodedWidth/Height`, `kPlex720pYuv420pBytes=1382400`; **DDR accept still rejects 720** (w-mem) |
| `plex_resolve.{hpp,cpp}` | Profile `720p` → 1280x720 / **3500** kbps / q70 / baseline / L31; validate allows exact path-720; ladder steps 4000…400 incl. 2500 |
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

| Arm | wall ms/f | fps ceiling | budget% |
|---|---:|---:|---:|
| 1280×720 @**1500**k default threads | **32.427** | 30.84 | 77.8% |
| 1280×720 @2500k | 36.845 | 27.14 | 88.4% |
| 1280×720 @3500k | 38.751 | 25.81 | 93.0% |
| 1280×720 @4000k default threads | **41.073** | 24.35 | 98.6% |
| 1280×720 @4000k threads=1 | 52.158 | 19.17 | — |
| 624×480 @1800k default threads | 15.969 | 62.62 | — |

- Budget 41.667 ms @24 fps. At 4000k decode alone **98.6%**; at **1500k content** headroom **9.24 ms (22.2%)**.
- **Tier choice worth 8.65 ms/f** (1500 vs 4000) — more than archived 480p present/DDR bucket.
- Discard synthetic 1080p blip 32.4 ms/f — not representative.
- 480p CPU-time 22.02 vs archived 21.562 (2.1%) — harness OK.
- Decode wall scales **0.836× linear-in-pixels** and **sub-linear in bitrate** (2.67× kbit → 1.267× time).
- **Dual product pin:** content/DP optimal **1500**; universal weak **3100** (geometry). Parent 1500 curve is of *already* 1280×720 — not PMS maxBR=1500 (which codes 720×404).

**Invalidated:** any plan that leaves present/pipe/scale on ARM at 720p; host “~70–120% if scale skipped” without fabric offload; pinning universal maxBR=1500 as true-720.

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

### Fit verdict (parent evidence #2 + #3)

Path tier: genuine 1280×720 + identity_skip (no ARM scale). Decode@**1500** content = **32.427 ms/f**.

Parent `ddr_write_bench` (device, true rc=0):

| arm | MiB/s | ms / 720p frame (1 382 400 B) |
|---|---:|---:|
| mapped bank `/dev/mem` | 86.676 | **15.210** |
| `--host-copy` ordinary RAM | 439.788 | 2.998 (upper bound — not bank) |
| 480p mapped bank | 89.363 | 4.795 |

| stack | ms/f | budget% | |
|---|---:|---:|---|
| decode1500 + mapped bank write | 32.427+15.210=**47.637** | 114.3% | **FAIL** (−5.97) |
| decode1500 + host-copy ceiling | 32.427+2.998=**35.425** | 85.0% | PASS-class if bank maps cached (+6.24) |

- **mmap cache policy RETRACTED by parent#4** — coherent flush *costs* +4.6 ms; best bank write stays ~15.28 ms/f. Serial decode+copy dead at every tier.
- Product present/DDR @480p archived **10.411** vs raw bank **4.795** → **2.17×** packing/stride overhead still on top of raw write.
- Prior ~22 ms / 59 MiB/s 720p copy figure was pessimistic; **15.21 ms @ 86.7 MiB/s** is the measured mapped rate. Conclusion “naive ARM copy does not fit” still holds at 1500k decode.
- Scale evacuation on true DP 720 remains **necessary**; path does not touch mmap.

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
- Parent #3: mapped-bank write **15.210 ms/f** @720p; host-copy ceiling 2.998 ms/f is hypothesis until WC/cached remap + **flush before doorbell**. Path pins content 1500 so decode leaves **9.24 ms** — not enough for today's 15.2 ms bank write.

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

See `LAB_PMS_720_DAEMON_PATH.md` + `BITRATE_1500_VS_GEOMETRY.md`.

**Dual pin (landed `eb4a832e`):** `kPlex720pDecodeOptimalBitrateKbps=1500` (DP/content); `kPlex720pWeakBitrateKbps=3100` (universal geometry floor). Lab fine matrix: maxBR=3000→720×404; **3100→1280×720** (content ~2585k). maxBR=1500→720×404.

OSD product: `OSD_TIER11_720P` default **0**; when 1, O[5:4]=11 → Path720p.

### Commit tip (w-path-720p)
- `eb4a832e` dual bitrate pin + 1500 geometry NEG probes
- prior: lab 720 daemon path, OSD tier11 flag, Path720p ladder, DP identity


See `GEOMETRY_FLOOR_3100.md` — universal weak pin lowered 3500→**3100** after fine matrix.
