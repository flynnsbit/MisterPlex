# 720p I-frame CABAC bin budget

Clock lock: **clk_ddr = 90 MHz**. One regular bin per cycle is the Phase 0 engine.

| Cap | Cycles / frame | Hard bin budget (1 bin/cycle) |
|---|---|---|
| 720p30 | 90e6 / 30 = **3,000,000** | 3.00 Mbins |
| 720p24 (fallback) | 90e6 / 24 = **3,750,000** | 3.75 Mbins |

Luma pels at 1280×720: **921,600**. 4:2:0 samples: **1,382,400**.

## What fits

Typical constrained Main I (CTB 32, QP ~22–28, no tiles): **~0.4–1.5 bins/luma-pel** → **0.4–1.4 Mbins**. Fits 720p30 with margin.

Dense I (screen content, QP ≤ 18, almost every coeff coded): **~2–3 bins/luma-pel** → **1.8–2.8 Mbins**. Fits 720p30 only if the engine stays **1 bin/cycle** and the rest of the pipe does not stall CABAC.

Worst legal I (all cbf=1, long coeff remainders): **~4–6 bins/luma-pel** → **3.7–5.5 Mbins**. **Misses 720p30.** Product response is **cap 720p24** or reject (not a slower CABAC clock).

## What fails (do not design)

- 2-cycle/bin at 20 MHz → 10 Mbins/s. 720p30 I peak needs tens of Mbins/s. **Known fail.**
- CABAC on **clk_sys** (typically 20–27 MHz class on this core) cannot hold 720p30 I.
- Dual-bin parallel CABAC in the leftover **~32k ALM** is out of Phase 0.

## Engine contract

`hevc_cabac` on `clk_ddr` reports `bins_this_pic` and `pic_over_budget` against **3,000,000**.
ctb_ctrl must not starve `req_valid` for a full I-frame if we claim 720p30.

H.264 apply_itu_fix stays false. This folder is not compiled into the H.264 RBF.
