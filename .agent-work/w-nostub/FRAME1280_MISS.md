# FRAME_1280 — prereg vs reality

REF: w-nostub-frame-1280 after edits
base: 3fa01a9b

## rtl-lint
PREREG_RC: 0 or 1
ACTUAL: make rtl-lint true rc=0 (QSF-only AND after present_core layout select)
MISS: none on lint — elaborate succeeded first try at FRAME_W=1280 FRAME_H=720

## Predicted breaks vs actual
| # | Prediction | Actual |
|---|------------|--------|
| 1 | bit truncations | no new owned regressions (baseline only) |
| 2 | CODED 624 vs FRAME 1280 | lint OK; **fixed proactively** via FRAME_GEOM_1280 → DDR_FRAME_720P_* |
| 3 | stride 512K | lint OK; **selected** DDR_FRAME_720P_YUV420P_BANK_STRIDE=0x180000; + $error if I420>stride |
| 4 | define-parity | true rc=0; FRAME_W=1280 FRAME_H=720 shared |
| 5 | colorbars | no fail |
| 6 | STORE_X_SCALE overflow | no fail |
| 7 | Template V_STORE=240 hardcoded | **CONFIRMED residual** — elaborates; product still maps store through 529×240 Template DE when macros off. Not a lint fail. Needs PRESENT_MULTI_PIXEL/beam L4 for true 1280 DE 1:1. |

## Unexpected finds
- Plex.sv already scales HPS_BANK_STRIDE_BYTES from FRAME_BYTES (→ 2097152 at 1280×720) but present_core **ignored** it and hard-pinned DDR_FRAME_YUV420P_BANK_STRIDE (512KiB). That was the silent landmine at the RTL bind site, not only the parameter default on ddr_frame_store.
