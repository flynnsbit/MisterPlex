# Parent checklist — apply `clk_pix` PIX24 (device must be healthy)

**Do not run while the MiSTer is wedged.** Power-cycle first; confirm control arm recipe.

## Preconditions
- [ ] Device up: ping OK, HDMI capture non-black via `scripts/hdmi_capture_idle.sh`
- [ ] Baseline RBF known (`c5382bee` / current proven)
- [ ] Exclusive Quartus slot free
- [ ] Integration multi-pixel Stage 0 (geometry @ same-clock) already green **or** combined grant

## Exact PLL edit (`pll_0002.v` only — SoT)

```verilog
.fractional_vco_multiplier("true"),
.number_of_clocks(4),
.output_clock_frequency0("20.000000 MHz"),  // UNCHANGED
.output_clock_frequency2("90.000000 MHz"),  // UNCHANGED
.output_clock_frequency3("29.700000 MHz"),  // NEW clk_pix
```
`pll.v`: add `outclk_3`. Packing `{outclk_3,outclk_2,outclk_1,outclk_0}`.

## Plex.sv
- Remove placeholder `assign clk_pix = clk_sys` under `PRESENT_CLK_PIX_PLL`
- Wire `.outclk_3(clk_pix)` on `pll`

## QSF / defines (integration fit only)
```
PRESENT_MULTI_PIXEL
PRESENT_PX_PER_CLK=2
PRESENT_CLK_PIX_PLL
```
**Must not** be on the default product path that must stay bit-identical to proven core.

## Gates before deploy
```bash
make clk-pix-pll-plan          # still expects PROPOSED until you flip contract status
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
