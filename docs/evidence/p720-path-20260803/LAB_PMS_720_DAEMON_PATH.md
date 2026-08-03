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

Parent device: 720p@**4000k** decode = **41.073 ms/f** (98.6% of 41.667 budget).

| maxVideoBitrate | Geometry (16:9 lab rk2) | Role |
|---:|---|---|
| **4000** | true 1280×720 | **Product pin** (margin above gate; matches parent measure) |
| **3500** | true 1280×720 | Geometry **minimum** — parent should measure decode ms/f |
| ≤3000 | **720×404** | FAIL true-720 — do not pin |

**Ask parent to measure on device:** 3500 vs 4000 CB 1280×720 real content wall ms/f.
If 3500 saves meaningful decode ms without leaving geometry, consider product pin 3500;
until then keep **4000**. Do not go ≤3000.

Direct Play native 720 remains cheapest when Part is CB-eligible.
