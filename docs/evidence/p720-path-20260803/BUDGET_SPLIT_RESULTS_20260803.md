# Budget split + threading — sequential answers (2026-08-03)

Lane w-path. Parent 34.50 = 26.08 (FFmpeg path) + 8.42 (DDR copy). Budget @30 = 33.333.

## (1) Code — no AVCodecContext

`rg avcodec_open2|AVCodecContext|thread_count|thread_type|sws_scale|sws_getContext arm/misterplexd` → **no matches**.
`rg -threads arm/misterplexd` → **no matches**.

Decode = forked FFmpeg CLI (`media_player.cpp:3219+`). Product FPGA path `-pix_fmt yuv420p` (`:3189-3192`, `:3310-3311`). No in-process `sws_*`.

Evidence class: **code does not contain X**.

## (2) Split (pre-reg then measure)

Pre-reg: `BUDGET_SPLIT_PREDICTIONS_20260803.md`.

Method: `build/ffmpeg_cpu_probe` + host `ffmpeg` on `probe_run/proxy_960x540_30.mp4`, 360 frames; host child-CPU ratios × parent 26.08; copy kept parent 8.42. Log: `probe_run/budget_split_measure.txt`. All `true rc=0`.

| bucket | predict | measured map | hit? |
|--------|--------:|-------------:|------|
| decode | 14–17 | **14.03** | HIT |
| pack/raw I420 | 8–12 | **12.05** | borderline miss (+0.05) |
| convert/scale (product identity) | 0–3 | **~0.45** forced-scale tax | HIT |
| RGB convert (not product) | — | **~+22.4** if rgb24 | — |
| copy-to-DDR | 8.42 | **8.42** parent | — |
| **total** | 34.50 | **34.50** | FAIL @30 by −1.17 |

**Colour-to-fabric prize ≈ 0** (already yuv420p).

## (3) Threading

Log: `probe_run/budget_thread_measure.txt`. All `true rc=0`.

| mode | null wall ms/f | null pct 1c | raw cpu ms/f |
|------|---------------:|------------:|-------------:|
| **default (product)** | **0.262** | **344.6%** | 1.524 |
| `-threads 0` | 0.247 | 351.9% | 1.505 |
| `-threads 1` | 0.551 (**2.1× worse**) | 116.7% | 1.341 |
| `-threads 2` | 0.421 (**1.6× worse** wall than default) | 178.5% | 1.425 |

**Finding:** product default **already multi-threaded**. Explicit `-threads 2` does **not** beat default wall. `-threads 1` is a large decode regression.

**Device total with threading “enabled”:** still **34.50 vs 33.333 → FAIL −1.17**. No unlock.

**Method trap (published miss if used):** scaling 26.08 by *sum-CPU* ratio makes t1 look “cheaper” because the second core is idle — that is not wall-time and must not be used for the deadline.

## Recommendation

- Do **not** wire `-threads 2` expecting a 540@30 win.
- Do **not** dispatch I420→RGB fabric convert for this budget.
- Remaining unlock for 540@30: cut **copy 8.42** and/or pack path; else keep dual tier **540@24 / 360@30**.
- `ddrFrameGeometryForFpgaPresent` untouched.
