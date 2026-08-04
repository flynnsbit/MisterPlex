# clk_pix refresh + raster assert (device-checkable)

## Product: 28.800000 MHz on shared `pll_0002` outclk_3

| Item | Value |
|------|--------|
| H_TOTAL × V_TOTAL | **1600 × 750** |
| clk_pix | **28.800000 MHz** |
| fps_eff | **24.000 Hz exact** |
| VCO | **720 MHz** (M=72 N=5 from 50 MHz; PFD=10 MHz) |
| Counters | C20=36, C90=8, Cpix=25 |

Independent check: `1600*750*24 = 28_800_000`; `720/20=36`, `720/90=8`, `720/28.8=25`.

### Why not 29.7 / dedicated PLL / 30 MHz
- **29.7 on shared VCO** with 20+90 needs min VCO 5940 MHz (OOR) — parent-measured.
- **Dedicated second PLL** withdrawn (placement/reset/async risk; parent).
- **30 MHz @ H1650** → 24.242 Hz (+1.01% judder) — **retired false product**.

### SDRAM note
142 MHz does not share VCO 720 with 20/90/28.8. Prefer **120 MHz** (`720/120=6`) if SDRAM is ever live. Today DDR_FRAME_STORE prunes SDRAM outclk.

## Measure

`fps_x10 = (SYS_HZ × 10) / period_sys` — PASS **[239,241]** (center 240).
**REJECT [242,244]** (defect). Trap **[150,170]** (~16.67 Hz @ 20 MHz H1600).

Raster (rd-duck): CE/frame=1_200_000, lines=750, CE/line=1600, DE=921_600, underrunΔ=0.

Fabric 24.000 is **necessary not sufficient** (HDMI may be 60 Hz scaler path) — parent also needs unique-frame / post-FIFO evidence.

## Parent command

```bash
./scripts/check_clk_pix_refresh.sh
# Expect: clk_pix_meas_verdict=PASS_240HZ_PRODUCT
python3 scripts/check_clk_pix_sta_guard.py STA_RPT=OUT/Plex.sta.rpt
```
