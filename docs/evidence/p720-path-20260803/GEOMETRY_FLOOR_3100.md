# Universal true-720 geometry floor is maxBR=3100 (not 3500)

**Method:** daemon-shaped universal URL (`videoResolution=1280x720`, MiSTerPlex
profile, unique session), lab PMS rk2 1920×1080 16:9. Decision XML + start.mp4
ffprobe. Spaced requests (3s) after concurrent 400s.

## Pre-registered predictions
- P1: 3000 → 720×404 (known) — **HIT**
- P2: 3200 → 1280×720 (decision earlier said so) — **HIT**
- P3: 3100 unknown — **HIT true 720** (new floor)
- P4: 3500 still 720 — **HIT**

## Verified matrix (start.mp4 HTTP 200 + ffprobe)

| maxBR | q | decision coded | decision content BR | ffprobe coded | SAR |
|---:|---:|---|---:|---|---|
| 3000 | 70 | 720×404 | 1667 | **720×404** | 404:405 |
| **3100** | 70 | **1280×720** | **2585** | **1280×720** CB L31 | **1:1** |
| 3150 | 70 | 1280×720 | 2650 | 1280×720 | 1:1 |
| 3200 | 70/100 | 1280×720 | 2650 | 1280×720 | 1:1 |
| 3500 | 70 | 1280×720 | 2979 | 1280×720 | 1:1 |

Artifacts: `probe_run/vf_rk2_br*_decision.xml`, `*_ffprobe.txt`, `lowbr_verify.txt`.

## Product impact
- Coarse matrix (3000 jump to 3500) **overstated** geometry floor.
- Product `kPlex720pWeakBitrateKbps` / `kPmsTrue720pMinBitrateKbpsMeasured` → **3100**.
- PMS **under-runs** the cap: maxBR=3100 → ~**2585** kbps content.
- **Parent measured (in-session, 2026-08-03):** already-1280×720 @**2600k** =
  **36.27 ms/f** (margin 5.40 ms @24fps). Same-session 2500k = 35.87 ms/f
  (archived cross-session 36.845 was ~0.8 ms high — do not interpolate sessions).
- Still **no** universal path to true 720 at ≤3000 / 1500. DP of ~1500k native
  720 remains the only way to that decode tier.

## Ladder / profile
- MiSTerPlex.xml does not set a min bitrate; PMS discrete quality steps do.
- videoQuality 40–100 does not move the 3000/3100 geometry cliff.
- Cannot get 1280×720 below maxBR 3100 on this lab PMS with current knobs.
