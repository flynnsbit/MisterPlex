# clk_pix PLL plan (w-clock) — design only, NOT applied

**Status:** proposal. No PLL edit. No fit. Parent grant required.

## Why
P1 multi-pixel drains N-wide fabric RGB on `clk_sys` into `async_fifo`, then
1 px/clk on `clk_pix` for MiSTer `CE_PIXEL` / ascal (1 RGB per CLK_VIDEO tick).

Today: `CLK_VIDEO = clk_sys` (20 MHz), `ce_pix=1` under PRODUCT_V_480.
Native 720p glass needs a pixel clock near the CEA rate, **not** a faster clk_sys.

## Targets (pixel clock, not clk_sys)

| Glass | Pixel rate | clk_pix need @1 px/CE | Notes |
|-------|------------|----------------------:|-------|
| Template 480p-class (ship) | ~20.06 Mpix/s | = clk_sys 20 MHz | status quo |
| CEA 720p24 | 29.70 MHz | **29.70 MHz** | 1650×750×24 |
| CEA 720p60 | 74.25 MHz | **74.25 MHz** | standard HDMI 720p |
| Content-only 720p24 (no blanking tax) | 22.12 | lab only | not a legal CEA mode |

`clk_sys` stays ≤ nostub Fmax (32.59 measured) and does N-wide work.
`clk_pix` is a **separate** PLL output sized to the glass, not an overclock of fabric logic.

## PLL source of truth
Only `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` (megawizard `pll.v` strings STALE).

Current outs (shipping):
- out0 `20.000000 MHz` = clk_sys
- out2 `90.000000 MHz` = clk_ddr

**Proposed (NOT applied) — need free C0/C1/C3/C4 inventory from megafunction:**
- Keep out0 clk_sys at 20.0 (or Target B 30.0 only if parent still wants 1ppc headroom)
- Keep out2 clk_ddr 90.0
- Add/reassign one out as clk_pix:
  - Lab 720p24: `29.700000 MHz` (50 × 297/500 or exact fractional — **must match ALTPLL legal K/M/N**)
  - Lab 720p60: `74.250000 MHz` (common MiSTer HDMI rate)

Exact fractional strings: **unknown until** `pll_0002.v` counter parameters are derived
with the Quartus PLL GUI or `altera_pll` legal check. Do not invent M/N.

## Top-level wiring (Plex.sv) — when granted
1. `wire clk_pix` from new PLL out; locked gated with existing pll lock.
2. `present_npx_path.clk_pix = clk_pix` (not clk_sys).
3. `CE_PIXEL` / `CLK_VIDEO`: product mux
   - default OFF: `CLK_VIDEO=clk_sys`, CE from present_core as today
   - multi-pixel ON: `CLK_VIDEO=clk_pix`, `CE_PIXEL=present_npx_path.out_ce` (or 1 if clk_pix==pixel rate)
4. SDC: `derive_pll_clocks` already; add generated clock name comments; **no false_path**
   on the FIFO data path (gray CDC only on pointers — already in async_fifo).
5. CDC inventory update: clk_sys ↔ clk_pix is the new related/unrelated pair.

## Related vs unrelated
If clk_pix and clk_sys share the same PLL VCO they are **related** — STA can time
them with a tight edge. Prefer that over a second PLL. Ratio 20:29.7 and 20:74.25
are not integer; edge windows need real STA (unknown until fit).

## What must pass before enable
1. nostub BUILD_OK (w-nostub)
2. Parent fit grant with `PRESENT_MULTI_PIXEL` still OFF first (reclaim only)
3. Second grant: macro ON + clk_pix out + ONE menu deploy
4. STA: clk_sys Fmax still ≥ required N-ppc rate; clk_pix domain met
5. HDMI DE_LAG resweep (Template lock breaks at H_DE=1280)

## Explicit non-goals this file
- Does not bump HPS/DDR3 hard-IP clocks
- Does not claim 74.25 is fittable in fabric logic (only as IO pixel clock)
- Does not replace w-scaler content window work
