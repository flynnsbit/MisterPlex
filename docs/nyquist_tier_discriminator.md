# 240-vs-480 Nyquist tier discriminator

## Problem

Ordinary video is band-limited below the store sampling ceiling. Spectral tests
on real content were **INCONCLUSIVE** (parent: cutoffs 0.033–0.17 vs predicted
0.333/0.413). The fixture must place **full-contrast energy at vertical Nyquist**.

## Live chain to design for (parent-verified, not assumed)

- Core emits **529×240** class fetch: `H_DE=529`; legacy `V_STORE=240` with
  `STORE_Y_SCALE=2` → **even store rows only** (50% of 480 rows never fetched).
- **17.3%** of columns never fetched (529/640).
- Then **ascal** + **HDMI grabber** (two further resamples).
- Tree `present_core.sv` may show `NATIVE_V_1TO1` when `FRAME_H>240`; fixtures
  still target the **measured** even-row path so they remain valid on live RBF.

Host model: `tools/present_chain_sim.py`.

## Assets

| file | coded size | body pattern |
|------|------------|--------------|
| `disc_nyquist_480p_624x480.mp4` | 624×480 | row y even=white / odd=black (period-2) |
| `disc_nyquist_240p_320x240.mp4` | 320×240 | same period-2 at native 240 |

Both: glass ID band (`G n=DDDDDD c=C` + bars), CB H.264 no-B, 24/1, AAC.
Side panel: period-8 row bands (survives cull as period-4) — large, high contrast.
Red ticker bar ≥16px tall (even-aligned) for motion without 1px features.

## Predicted glass signature (host-sim, then parent confirms)

| tier | after even-row cull |
|------|---------------------|
| 480 Nyquist period-2 | **FLAT** body (all fetched rows same phase) |
| 240 Nyquist, bilinear→480, then cull | **Not the same flat extreme**; residual std/rowdiff differs |

w-instr: score body ROI below ID band; metric `even_odd_abs` / `luma_std` on
capture. Do not use PLXD `frames_done`/`presents`/`drops` (void on c5382bee).

## Generator / gate

```bash
python3 scripts/gen_nyquist_tier_discriminator.py --out-dir DIR --duration 30
python3 tools/verify_nyquist_tier_discriminator.py --p480 ... --p240 ...
```
