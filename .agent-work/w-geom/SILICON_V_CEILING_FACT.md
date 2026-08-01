# FACT — vertical store ceiling on glass (parent 2026-08-01)

**Status:** ESTABLISHED FACT. Do not re-infer. Do not weaken.

## Artifact chain
| Item | Value |
|------|--------|
| RBF | `c5382bee` md5-verified on device |
| Path | product `FpgaSpi::publishDdrFrame` via `push_frame --ddr --pattern` |
| Codec | **out of loop** (H.264 band-limits below the ceiling) |
| Instrument | HDMI capture mean/std on flat even/odd rasters |

## Pre-registered results (5/5 hit)
```
mid_grey  CONTROL  mean=137.0  std=0.00
even_black         mean=  7.0  std=0.00  → solid BLACK
even_white         mean=255.0  std=0.00  → solid WHITE
odd_black          mean=255.0  std=0.00  → solid WHITE (INVERTED)
odd_white          mean=  7.0  std=0.00  → solid BLACK (INVERTED)
```

**`std=0.00`:** no stripes — odd store rows are **entirely absent**. Mechanism matches pre-T7 RTL: `store_y = py*2` / `V_STORE=240` → only even rows fetched. **50% of rows never reach glass.**

## Scope limits (do not overclaim)
- **Vertical only** proven on pixels.
- Horizontal 529/640 remains **arithmetic** (clk_sys=20 MHz → max H_total≈636 < 640). Not pixel-proven here.
- FRAME_LEDGER / presents / drops = ARM supply only (`fpga_obs=none`).
- PLXD[63:48] on this RBF = **vsync** (`bank_vsync_count`), not swaps.

## After T7 RBF — required falsifier
Identical card must **break** solid-field collapse:
- odd_black → black (not white)
- odd_white → white (not black)
- preferably stripes or matching phase, **not** inverted solids
- mid_grey control still flat

Parent owns the capture. w-geom does not touch the device.

## Retractions (do not build on)
1. `p_ge50=14.5%` UNSCORED (σ contamination; raw log gone)
2. "two instruments agree" withdrawn (one series)
3. drops=0 is supply, not display
4. frames_done-derived claims void until frames_done_d2 RBF
