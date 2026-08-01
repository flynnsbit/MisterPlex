# Fleet facts absorbed (parent 2026-08-01) — w-cpu

## Established FACT (viewed pixels, 5/5 pre-reg)

Vertical ceiling: odd store rows **absent**. `std=0` solid-field invert under one-row phase.
Product path `publishDdrFrame`, H.264 out of loop, RBF `c5382bee`.
**50% of rows never reach display.** Horizontal 529/640 still arithmetic-only.

T7 after = must **break** solid-field collapse on same card.

## Retractions (do not build on)

1. raw `p_ge50=14.5%` → **UNSCORED** (σ≫mean; log gone — remeasure trimmed)
2. "two instruments agree" withdrawn (p_ge50 + acf same series)
3. `drops=0` = ARM supply not display; `unaccounted`≡`residual` print twice
4. PLXD `frames_done` on c5382bee = **vsync counter**

## Standing rule

Publish no field name without derivation in the same breath.

## Safety defect → ARM fix shipped this lane

`frames_done` advance alone as PLXD liveness → freeze looks healthy on c5382bee.
**Fix:** `host/libmisterplex/plxd_liveness.hpp` — progress = free/disp/swap identity change.
Wired in `fpga_spi.cpp` sendDdrFrame. Unit: `test_plxd_liveness`.
Deploy tip daemon to get it live; tip RTL frames_done_d2 still needs new RBF for honest swap count in that field.

## CPU lane unchanged priority

Trimmed A/B Main STOP: `SOAK_AB_MISTER_QUIESCE_PGE50.md` — score `p_ge50_steady` not raw.
