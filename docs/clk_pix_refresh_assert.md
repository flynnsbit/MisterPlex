# Falsifiable refresh assertion (w-clock)

## Trap
`fps_eff = clk_pix / (H_TOTAL * V_TOTAL)` with COMPACT H=1650 V=750 (1_237_500):
| clk_pix | fps_eff | fps_x10 |
|--------:|--------:|--------:|
| 29.7 MHz | **24.000** | **240** |
| 20.0 MHz | **≈16.162** | **≈162** |

Still HDMI frames cannot distinguish these. Geometry-only 720p is unfalsifiable.

## Fabric measure (Gray counters — rd-duck NACK fix)
`plex_clk_status` does **not** edge-detect `clk_pix` in `clk_sys` (Nyquist-illegal when
pix > sys/2). Instead:

1. Free-running binary counters in the **clk_pix** domain (pix edges, `ce_pix` pulses, `de` high-cycles).
2. Binary→Gray encode in source domain.
3. 2FF sample Gray into `clk_sys`, Gray→bin, unsigned delta over `WIN_CYC` (default 1 s @ 20 MHz).
4. VSync rises: 2FF edge-detect in sys (slow; legal).

Sticky outputs after first full window:
- `meas_fps_x10` = observed_frames × 10
- `meas_pix_count` / `meas_ce_count` / `meas_de_count` = Gray deltas
- `meas_flags` = `{0, de_ok, ce_ok, trap16, pll_on, fps_ok, pix_ok, valid}`

Wired in `Plex.sv`: `clk_pix`, `VSync`, `ce_pix`, `de=~(HBlank|VBlank)`.
Under `PRODUCT_NO_STUB`: status raw[14]=fps_x10, raw[15]=flags.

## Predicate
| Result | Condition |
|--------|-----------|
| **PASS** | fps_x10 ∈ **[230, 250]** AND valid AND fps_ok AND **pix_ok** AND !trap16 |
| **FAIL trap** | fps_x10 ∈ **[150, 170]** |
| UNKNOWN | else (wait ≥1 s after load; check PLL) |

Gap trap_hi→pass_lo = 60 x10 units (6 Hz) — no overlap.
`pix_ok`: Gray delta within ±2% of `PIX_HZ * WIN_CYC / SYS_HZ`.
`ce_ok` / `de_ok`: secondary (reported; DE band = active aperture × fps_eff).

## Parent commands (device — agents do not run)
```bash
# After core load, wait ≥2 s for measure window
./scripts/check_clk_pix_refresh.sh
# or:
set_status --raw
# Expect: clk_pix_meas_verdict=PASS_24HZ_BAND   (fps_x10~240, pix_ok=1)
# Trap:   clk_pix_meas_verdict=FAIL_16HZ_TRAP   (fps_x10~162)

python3 scripts/hdmi_measure_refresh.py --seconds 2
# PASS 23.0–25.5 Hz; FAIL trap 15.5–17.0
```

## Negative proof
`tests/unit/test_plex_clk_refresh_meas_verilator.sh` runs POS_24Hz and NEG_16HZ_TRAP.
`tests/unit/test_clk_pix_refresh_predicate.py` locks arithmetic bands.
