# 640×360 @30 predictions (pre-registered before measure) — w-path 2026-08-03

Hypothesis (parent): frame-rate-aware tiers —
- 23.976/24 → 960×540 @24, 4/3 polyphase (detail)
- 29.97/30 → 640×360 @30, exact 2× doubling (motion, no judder)

Baseline (parent device, tight 960×540): decode+sws **26.08** + copy **8.42** = **34.50** ms
@ structural copy **88.045 MiB/s**. Deadline @30 = **33.333** ms.

## Pixel / byte ratios vs 960×540

| | 960×540 | 640×360 | ratio |
|--|--:|--:|--:|
| pixels | 518400 | 230400 | **0.4444** |
| I420 B | 777600 | 345600 | **0.4444** |

## Pre-registered cost predictions (build-host method + scale from 540)

Assume decode+sws tracks pixels linearly (same codec class CB L3.x, similar bitrate density).
Copy tracks bytes @ 88.045 MiB/s.

| term | formula | prediction |
|------|---------|------------:|
| copy ms | 345600 / (88.045×1024²) × 1000 | **3.74** |
| decode+sws ms | 26.08 × 0.4444 | **11.59** |
| **total ms** | | **15.33** |
| vs 33.333 (30 fps) | | **+18.00 PASS** (wide) |
| vs 41.667 (24 fps) | | **+26.34 PASS** |

### Confidence / miss modes
- **P-cost:** total ∈ **13–18 ms** on a method comparable to the 540 baseline class.
  Outside 10–22 ms = miss worth explaining (non-linear decode, host≠device, etc.).
- **P-device-scale:** if only host wall times available, report host absolute AND the
  scaled-from-540 estimate separately — do not claim device 15.33 without ARM soak.

## PMS delivery predictions (640×360 ceiling)

| ID | Prediction |
|----|------------|
| **P-del-1** | HD 16:9 + maxBR≥**750–1000** → display near **640×360** (ceiling fit). Knee may be lower than 540’s 2000. |
| **P-del-2** | maxBR too low (e.g. 400) → shorter coded height (same trap class as 720×404). |
| **P-del-3** | 29.97 source uncapped → rate **pass-through** 30000/1001 at 640×360. |
| **P-del-4** | SAR 1:1 square-pixel on HD 16:9 (same class as 540). |
| **P-del-5** | 360 is not MB-aligned (360&15=8) → SPS coded height **368** with bottom crop 8 → display **360**; ARM I420 **345600** after libav crop. |

## Product-detail prediction (subjective, pre-stated)

640×360×2 will look **noticeably softer** than 960×540×4/3 on static text/UI and fine
detail (≈0.44× source samples). On camera pans / sports, **no 5:4 judder** beats soft
glass for many users. **Prediction:** ship **both** tiers; default film→540, TV→360;
do **not** replace 540 with 360 globally.

## Geometry / fabric notes (not measured here)

- Exact 2×: 640→1280, 360→720 — no polyphase phase ROM; immune to 4/3 phase-index bugs.
- Storage selector must identity 640×360 (not force 624×480 canvas) or we re-kill the budget.
- `coded_size` today rejects **640×480** as presented; **640×360** must remain legal DECODE.

---

## Outcomes — see `T360_RESULTS_20260803.md`

| ID | Outcome |
|----|---------|
| P-cost | **HIT** — device-class total **18.05 ms** (+15.28 @30); band 13–18 |
| P-del-1..5 | **HIT** — knee **1000**; SPS 368→360; 29.97 pass-through |
| Product | Ship **both** tiers; film→540@24, TV→360@30; do not replace 540 |
