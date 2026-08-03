# Parent checklist — apply `clk_pix` PIX24 (device must be healthy)

**Do not run while the MiSTer is wedged.** Power-cycle first; confirm control arm recipe.

## Preconditions
- [ ] Device up: ping OK, HDMI capture non-black via `scripts/hdmi_capture_idle.sh`
- [ ] Baseline RBF known (`c5382bee` / current proven)
- [ ] Exclusive Quartus slot free
- [ ] Integration multi-pixel Stage 0 (geometry @ same-clock) already green **or** combined grant

## PLL / wiring — **LANDED under ifdef** (this branch)

Source already contains (default OFF = 3-clock shipping):
- `pll_0002.v`: `PRESENT_CLK_PIX_PLL` → `number_of_clocks(4)`, `outclk_3="29.700000 MHz"`, fractional true
- `pll.v`: `outclk_3` port under same ifdef
- `Plex.sv`: `.outclk_3(clk_pix)`; no placeholder tie when macro ON

## QSF / defines (integration fit only — parent enables)
```
PRESENT_MULTI_PIXEL
PRESENT_PX_PER_CLK=2
PRESENT_CLK_PIX_PLL
```
**Must not** be on the default product path (bit-identical when unset).

## ascal / CEA
Core raster feeds **ascal input**; HDMI is `video_mode` (720p60). Core need **not**
be VIC-legal. See `ASCAL_VS_CORE_RASTER.md`. 29.7 MHz remains correct.

## Gates before deploy
```bash
make clk-pix-pll-plan          # LANDED_IFDEF_DEFAULT_OFF; 3-clk default + 29.7 under ifdef
make present-720p-fit-contract
make post-fit-timing STA_RPT=...   # clk_sys≥20, clk_pix≥29.7, no neg slack
make post-fit-hierarchy FIT_RPT=... # u_mp_npx_path, u_mp_beam, u_mp_rate non-zero
```

## Deploy (parent only)
```bash
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh
scripts/hdmi_capture_idle.sh /path/cap.png
# Expect: ACTIVE toward 1280×720 class; CYAN if fabric idle; not 16 Hz tear if ascal masks
```

## Rollback
- Rebuild without `PRESENT_CLK_PIX_PLL` / multi-pixel macros
- Or reload known-good RBF from SD baseline
