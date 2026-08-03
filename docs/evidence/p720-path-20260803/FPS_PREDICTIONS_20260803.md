# Frame-rate predictions (pre-registered before measure) — w-path 2026-08-03

Budget baseline (parent): tight 960×540 decode+sws+copy = **34.50 ms**.

| Source fps | Deadline ms | vs 34.50 | Prediction |
|-----------:|------------:|---------:|------------|
| 23.976/24 | 41.667 | +7.16 | PASS |
| 25 | 40.000 | +5.50 | PASS |
| 29.97/30 | 33.333 | -1.17 | **FAIL** serial path |

## PMS control predictions
1. **P1:** Universal API exposes a frame-rate lever (`maxFrameRate` / `videoFrameRate` /
   profile MaxFrameRate / Client-Profile-Extra). **Predict: YES** — Plex clients commonly
   send `maxVideoBitrate` + resolution; frame rate caps exist in XML profiles and often as
   query `frameRate` / `maxFrameRate` style params. Exact name TBD by code+probe.
2. **P2:** With no explicit cap, PMS **passes through** source frame rate on 960×540@2000
   for a 29.97 asset. **Predict: PASS-THROUGH** (transcode keeps source rate unless capped).
3. **P3:** Asking maxFrameRate=24 on a 29.97 source yields **~24 fps** delivery (or nearest
   supported), not 29.97. **Predict: HIT if lever works; MISS if ignored.**
4. **P4:** Best exact rational scale tier for 30 fps fallback (deadline 33.33, need ≲30 ms
   total with margin):
   - **853×480** (exactly 2/3 of 1280×720): I420=614160 B; copy@88 MiB/s≈6.65 ms;
     parent proxy 854×480 decode-only was ~20.70 → decode+sws ~24? total ~31 ms → **borderline PASS**
   - **960×540** at 30: **FAIL** (-1.17)
   - **640×360** (exactly 1/2): very safe budget, soft glass
   - **Predict ship fallback:** **853×480 (2/3)** if PMS delivers it; else **640×360 (1/2)**

## Fallback budget sketch (pre-measure; will correct)
| Tier | Scale to 1280×720 | I420 B | copy ms @88 | pred decode+sws | pred total | 30fps margin |
|------|-------------------|-------:|------------:|----------------:|-----------:|-------------:|
| 960×540 | 4/3 | 777600 | 8.42 | 26.08 | 34.50 | -1.17 FAIL |
| 853×480 | 3/2 W, 3/2 H (exact 2/3 of 720p) | 614160 | 6.65 | ~24 | ~30.7 | ~+2.6 thin |
| 640×360 | 2× | 345600 | 3.74 | ~15? | ~19 | +14 PASS |

Note: 854×480 is *not* exact 2/3 (1280*(2/3)=853.333→853). Prefer **853×480**.

---

## Outcomes (post-measure) — see `FPS_RESULTS_20260803.md`

| ID | Outcome |
|----|---------|
| P1 | **PARTIAL** — Extra `video.frameRate` works; universal query fps params ignored |
| P2 | **HIT** — uncapped rk142 → 30000/1001 @ 960×540 |
| P3 | **HIT** via Extra (MISS via query); daemon wires 540p → maxVideoFrameRate=24 |
| P4 | **Revised** — prefer fps cap @960×540; geometry fallback **640×360** (exact 2×). 853 is not exact 2/3 and not MB-aligned |
