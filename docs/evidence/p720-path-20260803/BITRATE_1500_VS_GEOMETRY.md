# 1500 kbit pin vs PMS geometry (w-path)

## Parent device (decode of already-1280×720 CB @ N kbit)

| kbit | ms/f | budget% | headroom |
|---:|---:|---:|---:|
| 1500 | 32.427 | 77.8% | 9.24 ms |
| 2500 | 36.845 | 88.4% | 4.82 ms |
| 3500 | 38.751 | 93.0% | 2.92 ms |
| 4000 | 41.073 | 98.6% | 0.59 ms |

**1500 content tier is worth +8.65 ms/f vs 4000** — real, measured.

## Lab PMS universal maxVideoBitrate (daemon URL, unique session)

| maxBR | coded (rk2 16:9 HD) | coded (rk7 native 720) |
|---:|---|---|
| 1500 (q40/70/100) | **720×404** | **720×404** |
| 2000–3000 | 720×404 | — |
| ≥3500 | **1280×720** SAR 1:1 | 1280×720 @4000 |

**HIT prediction:** cannot force 1280×720 at 1500 via universal maxBR/quality knobs.

## Product pin (landed)

| Knob | Value | Why |
|---|---:|---|
| `kPlex720pDecodeOptimalBitrateKbps` | **1500** | Parent decode budget for true-720 *content* / DP |
| `kPlex720pWeakBitrateKbps` (universal) | **3500** | Lab geometry floor for coded 1280×720 |
| Path720p default | preferDirect | DP of ~1500k 720p CB → ARM 32 ms class without PMS downscale |

**Do not set universal maxVideoBitrate=1500** expecting 1280×720 — lab proves 720×404.
**Do** stock/prefer Direct-Play 1280×720 CB ~1500k library assets for the decode win.
