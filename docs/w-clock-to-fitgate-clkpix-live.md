# w-clock → w-fitgate: clk_pix 29.7 LIVE on reconcile

Branch: `w-clock-clkpix-live` (base `origin/reconcile/main-2026-08-04`)

## Product QSF now ON
- FRAME 1280×720, FRAME_LINES_16
- PRESENT_MULTI_PIXEL + PRESENT_PX_PER_CLK=2
- **PRESENT_CLK_PIX_PLL=1** + active `Plex_clk_pix.sdc`
- COMPACT 29.7 MHz (H1650×V750×24) — not CEA VIC60 59.4

## STA PRE-REG (before your fit)
See `docs/clk_pix_29p7_sta_prereg.md`:
- P1 general[3] Fmax ≥ 29.7, slack ≥ 0
- P2 clk_ddr worst ≥ 0 (may erode from +0.311)
- P3 clk_sys ≥ +0.5 ns

## Device refresh check (parent runs, not agents)
`scripts/check_clk_pix_refresh.sh`
- status raw[14]=fps_x10 (240=24.0); ~161 = 16.16 trap
- raw[15] flags: bit0 valid, bit1 pix_ok, bit2 fps_ok, bit3 pll_on
- optional `scripts/hdmi_measure_refresh.py`

## T_copy
+8.962 ms remains PRE-REGISTERED arithmetic only; e2e OPEN until fabric DMA measured.

Please pull/merge this branch into the 720p integration candidate before the exclusive fit.
