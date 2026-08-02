# 475 vs 480 delivered rows — discriminating power (host)

**Miss on record:** predicted glass signature under 240-ceiling was “solid std≈0.4”;
measured was moiré/std~67. **What held:** only **period-2** discriminates
`store_y=py*2`; periods 4/8/16 are invariant (zero power). Apply the same
discipline here: reject features invariant under the 480→475 transform.

## Defect under test
Product ARM vf:
```
scale=618:480:flags=fast_bilinear:force_original_aspect_ratio=decrease,
pad=624:480:0+(618-iw)/2:0+(480-ih)/2:color=black
```
Host-measured on white 624×480: **618×475** then pad → **pad_top=2, pad_bot=3**.

## What has ZERO power (do not use)

| feature | why |
|---------|-----|
| FFT vertical pitch | 958/480×2=3.99 vs 958/475×2=4.03 vs measured 4.06 — **bin-locked**; parent already showed |
| Beat-count vernier (P & P+1) | Under **uniform scale**, beat length and active height scale together → **beat count invariant** |
| One-cycle phase ramp over frame | Slip = 360°×(5/480) ≈ **3.75°** — not localizable |
| Chirp “Nyquist null row” | Null shift only **0.021 src rows** at fine end; H.264 dominates |

## What HAS power

### PRIMARY — edge pad probes (integer)
Asset: `rowcount_vernier_624x480_24_120s.mp4` (white rows 0–3 & 476–479 after ID).

| hypothesis | pad_top | pad_bot | pad_total |
|------------|---------|---------|-----------|
| **H480** identity / no 618-shrink | **0** | **0** | **0** |
| **H475** product ARM vf | **2** | **3** | **5** |

Host on decoded frame 100: measured **0 vs 5** exactly.  
**Grabber condition:** coded edges must be visible. If overscan crops them → metric VOID (publish that).

### SECONDARY — multi-fiducial slope / span
13 ticks at source y=100…460 step 30. Host: span **360.00 vs 356.87** (Δ=3.13 src rows).

Linear fit `y_cap = a·y_src + b` with σ_centroid≈0.35 src-row (conservative):

| capture map model | Δa (cap px / src row) | SE(a) | z≈ |
|-------------------|----------------------|-------|-----|
| 480→958 (parent pitch grid) | 0.021 | 0.0017 | **~12** |
| 480→1080 | 0.023 | 0.0019 | **~12** |
| 480→720 | 0.016 | 0.0013 | **~12** |

**z≫3** even without edges — slope separates H480 (a∝1) from H475 (a∝475/480).

Span-only (two ends): z≈6.3 still OK; prefer full 13-point slope.

## Pre-registration (before glass)

| metric | predict H480 | predict H475 (product ARM) | power |
|--------|--------------|----------------------------|-------|
| pad_total | **0** | **5** | HIGH if edges visible |
| pad_top / pad_bot | 0 / 0 | 2 / 3 | HIGH if edges visible |
| body fiducial span (coded) | **360.0** | **356.9** | MEDIUM–HIGH |
| slope a / a_ref | **1.000** | **0.9896** | HIGH (z~12 host model) |
| FFT pitch | — | — | **NONE** |
| vernier beat count | — | — | **NONE** (invariant) |

## Asset / scan
- File: `~/plex/media/movies/MiSTerPlex Rowcount Vernier 624x480 24fps 120s (2026).mp4`
- Generator: `scripts/gen_rowcount_vernier_fixture.py`
- **ratingKey:** not in §2 until parent scans (was not present when inventoried)

```bash
curl -sS "http://YOUR-PLEX-SERVER:32400/library/sections/2/refresh?X-Plex-Token=$TOK"
```

## Answer to “is it impossible?”
**No — but pitch is impossible.** Integer pad and/or fiducial slope are the instruments.
