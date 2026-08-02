# Row-count precision fixture — 475 vs 480 delivered rows

## Verdict on approaches

| approach | works? | role |
|----------|--------|------|
| **Edge pad probes** (white on src rows 0–3 & 476–479) | **YES** | **PRIMARY** |
| **Counted fiducials** (13× 4-row ticks y=100…460) | **YES** | **SECONDARY** |
| Vernier P=19 vs 20 beat | **WEAK** on this encode | do not rely |
| Binary row column | **PARTIAL** (LSB dies in bilinear) | coarse only |

## Why pad probes win
Product ARM vf (host-measured on white field):
`scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black`
→ scale **618×475**, pad → **pad_top=2, pad_bot=3**, active **475**.

On **this encoded file** after decode (frame 100):

| path | pad_top | pad_bot | pad_total | top4_mean | body_fiducial_span | n_body_fids |
|------|---------|---------|-----------|-----------|--------------------|-------------|
| identity (no force scale) | **0** | **0** | **0** | 255.0 | **360.001** | 13 |
| + product ARM vf | **2** | **3** | **5** | 126.27 | **356.867** | 13 |

**Separation:** pad_total **0 vs 5** (integers). Span delta **3.13** source rows (~1%).

FFT pitch cannot resolve 475 vs 480 (parent: 4.03 vs 3.99 vs measured 4.06 bin). Pad count can.

## Pre-registration (glass)

| metric | predict if 480 rows (no 618-shrink / identity) | predict if product ARM 475+pad | separable on grabber? |
|--------|-----------------------------------------------|--------------------------------|------------------------|
| pad_total (black edge rows) | **0** | **5** (2 top + 3 bot) | **Y** if coded edges visible |
| pad_top | 0 | 2 | Y |
| pad_bot | 0 | 3 | Y |
| body fiducial span (coded rows) | **360.001** | **356.867** | Y (Δ≈3.1 rows → ~2× on 1080 capture) |
| vernier beat | — | — | **N** as sole metric (host acf weak) |

**Miss to publish if it happens:** coded top/bottom edges cropped by HDMI/ascal → pad_total unusable; fall back to fiducial span only and say so.

## Asset
- Repo: `assets/avsync/rowcount_vernier_624x480_24_120s.mp4`
- Media: `~/plex/media/movies/MiSTerPlex Rowcount Vernier 624x480 24fps 120s (2026).mp4`
- Generator: `scripts/gen_rowcount_vernier_fixture.py`
- ffprobe measured: 624×480, SAR 1:1, DAR 13:10, r=24/1, nb=2880, dur=120, CB, b=0

## PMS (parent)
```bash
curl -sS "http://YOUR-PLEX-SERVER:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
# ratingKey after scan — unknown until you scan
```
