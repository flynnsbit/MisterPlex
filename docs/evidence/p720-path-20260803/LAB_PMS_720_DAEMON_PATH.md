# Lab PMS 720p via daemon URL builder (w-path)

**Method:** `buildUniversalTranscodeUrl` + `plexFfmpegHeaders` (MiSTerPlex profile),
unique `session` per request (reused session polluted earlier captures).
**PMS:** lab `PMS_LAB:32400` section 2. Token not recorded.
**HTTP:** parent hand-curl 400s were request-shape/session — **not** PMS refusing 720p.

## HTTP 200 proof

| Asset | request | start.mp4 | decision coded | ffprobe coded | SAR | profile |
|---|---|---|---|---|---|---|
| rk2 1920×1080 16:9 | 1280×720 maxBR=**4000** | **200** | 1280×720 | **1280×720** | 1:1 | CB L31 |
| rk2 | 1280×720 maxBR=**3500** | **200** | 1280×720 | **1280×720** | 1:1 | CB L31 |
| rk2 | 1280×720 maxBR=**3000** | **200** | 720×404 | **720×404** | 404:405 | CB L31 |
| rk2 | 1280×720 maxBR=2500/2000 | **200** | 720×404 | 720×404 | 404:405 | CB L31 |
| rk7 native 1280×720 | 1280×720 maxBR=4000 | **200** | 1280×720 | **1280×720** | 1:1 | CB L31 |
| rk83 1440×1080 **4:3** | 1280×720 maxBR=4000 | **200** | 960×720 | **960×720** | ~1:1 | CB L31 |
| rk83 control | 624×480 maxBR=2500 | decision 200 | 624×468 | — | — | CB |

**Ceiling trap at 720p:** videoResolution is still a ceiling. 4:3 HD → **960×720** (not 1280).
16:9 HD bitrate-starved → **720×404** with mild SAR 404:405 (DAR 16:9) — **not** fabric-full 1280.

Artifacts: `probe_run/uniq_rk2_br*_ffprobe.txt`, `uniq_rk7_br4000_ffprobe.txt`, decision XML scrubbed.

## Bitrate pin recommendation (decode cost lever)

Parent device (decode of *already* 1280×720 CB @ N kbit):

| content kbit | ms/f | budget% |
|---:|---:|---:|
| 1500 | 32.427 | 77.8% |
| 3500 | 38.751 | 93.0% |
| 4000 | 41.073 | 98.6% |

Lab universal maxBR (any quality):

| maxVideoBitrate | Geometry (16:9 lab rk2) | Role |
|---:|---|---|
| **3500** | true 1280×720 | **Universal product weak pin** (geometry floor) |
| **4000** | true 1280×720 | Ladder step above floor |
| **1500** (universal) | **720×404** | FAIL true-720 — do not pin as universal maxBR |
| ≤3000 | **720×404** | FAIL true-720 |

**Dual product pin:** `kPlex720pWeakBitrateKbps=3500` (universal); `kPlex720pDecodeOptimalBitrateKbps=1500` (content/DP already-true-720). Prefer Direct Play of ~1500k native 720p CB for the +8.65 ms/f decode win. See `BITRATE_1500_VS_GEOMETRY.md`.
