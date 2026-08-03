# Fit survival — CDC + constrained paths (w-clock)

**No fit run by this lane.** Slack numbers below that are not quoted from a
`Plex.sta.rpt` are **unknown**. This note lists what is *constrained*, what is
*same-clock*, and what the parent must score after the exclusive fit.

## 1) Clock topology (shipping)

| Net | Source | Rate | SoT |
|-----|--------|------|-----|
| `clk_sys` | `pll_0002` out0 | **20.000 MHz** | `rtl/pll/pll_0002.v` |
| `clk_ddr` | `pll_0002` out2 | **90.000 MHz** | same |
| `clk_pix` (multi-pixel today) | **tied to `clk`** | 20.000 MHz | `present_core.sv` `u_mp_npx_path.clk_pix(clk)` |

`sys_top.sdc` places all fabric PLL `divclk` outputs in **one**
`set_clock_groups -exclusive` group. Therefore `clk_sys` and `clk_ddr` are
**related clocks** (not cut as whole domains). Documented related-edge on
shipping 20/90: **5.556 ns** (`Plex.sdc` comments; STA on `8fdf440f` path panels).

## 2) Multi-pixel CDC inventory (assembled path)

### A. Same-clock bring-up (integration default)

`clk_pix == clk_sys`. Domains collapse for STA.

| Crossing | Mechanism | STA treatment | Beat safety |
|----------|-----------|---------------|-------------|
| Beam → store `rd_x/y` | registered on `clk` | single clock | N/A |
| Store YUV → N-wide RGB | `yuv_bt601_npx` on `clk` | single clock | N/A |
| N-wide → 1 px (`present_npx_path`) | `async_fifo` still instantiated | **same clock both ports** | soak TB passes; gray ptr still correct |
| `in_ready` backpressure | combo/reg on `clk` | single clock | prevents fill>drain |

**Implication:** 720p24 @ 2 ppc “11.06 MHz fabric work” does **not** introduce a
new related-edge ratio. Timing risk is **datapath Fmax on `clk_sys`** (wider YUV,
beam, hold of RGB across CE gaps) — not a novel CDC edge family.

**Slack of that datapath: unknown until integration STA.** Parent gate:
`make post-fit-timing STA_RPT=...` (negative slack = hard fail).

### B. Future dual-clock (`clk_pix` PLL out — not applied)

When `CLK_PIX_PLL_PLAN` lands (e.g. 29.7 or 74.25 MHz), `present_npx_path` is the
only intentional multi-bit fabric→pix bridge.

| Path | Constrained how |
|------|-----------------|
| `async_fifo.mem[]` → `rd_data_r` | **`set_false_path` in `Plex.sdc`** (all instances, incl. `u_mp_npx_path`) |
| Gray wr/rd pointers | 2-FF sync inside `async_fifo` — **remain timed** (not false-pathed) |
| RGB outside FIFO | **must not** bare-wire; only FIFO data plane may use the cut |

Doctrine (`docs/cdc-crossing-inventory.md`): false_path on mem→rd_data_r is the
proven pattern (placement-fragile data RAM is asynchronous; pointers are the real CDC).
**Do not** cut whole `clk_sys`↔`clk_pix` or add multicycle to hide violations.

### C. Existing `clk_sys` ↔ `clk_ddr` (unchanged by multi-pixel beam)

Still the inventory in `docs/cdc-crossing-inventory.md` (#1–#15 want_y gray, toggles,
line dual-port M10K). Multi-pixel **reuses** `line_buf_ram` port B on `rd_clk=clk`
(same domain as port A read) — **not** a new DDR→sys ratio.

Dual-port B: both reads on `rd_clk` (`line_buf_ram.sv`). Write remains `clk_ddr`.
Same dual-clock M10K class as product.

## 3) What is constrained today (quoteable SDC)

From `fpga/Plex_MiSTer/Plex.sdc`:

```tcl
set_false_path \
	-from [get_keepers {*async_fifo*mem*}] \
	-to   [get_keepers {*async_fifo*rd_data_r*}]
```

Plus `derive_pll_clocks` / `derive_clock_uncertainty` and `sys_top.sdc` groups.

Gate: `scripts/check_present_720p_fit_contract.py` fails if this false_path is
removed or if `present_npx_path` stops instantiating `async_fifo`.

## 4) Paths parent STA must score (post exclusive fit)

When macros ON (`PRESENT_MULTI_PIXEL`, `PRESENT_PX_PER_CLK=2` or `4`):

1. **Fmax `clk_sys`** — include `yuv_bt601_npx`, `present_beam_ppc`, expander logic.
2. **Hold/setup on non-cut `clk_sys`↔`clk_ddr`** — want_y gray, line meta (existing).
3. **Hierarchy survival** (not STA, but fit-survival): non-zero rows for
   `u_mp_timing`, `u_mp_beam`, `u_mp_npx_path`, `fstore` / `gen_rd_npx_wide`.
4. If `clk_pix` separate: confirm false_path hits `u_mp_npx_path` FIFO keepers;
   gray pointer paths still have slack ≥ 0.

Commands (parent):

```bash
make post-fit-timing STA_RPT=path/to/Plex.sta.rpt
make post-fit-timing-margin STA_RPT=path/to/Plex.sta.rpt
make timing-exclusion STA_RPT=path/to/Plex.sta.rpt
make post-fit-hierarchy FIT_RPT=path/to/Plex.fit.rpt
```

## 5) Honest pre-fit risk board

| Risk | Severity | Evidence class |
|------|----------|----------------|
| Same-clock 2ppc Fmax regression vs 32.04 nostub | **MEDIUM** | unknown — needs STA |
| Same-clock 4ppc Fmax (4× BT.601) | **MEDIUM–HIGH** | unknown — wider ALM path |
| CDC gray ptr fail same-clock | LOW | soak TB 4096 groups rc=0 |
| Dual-clock pix when PLL added | MEDIUM | false_path present; dual-clock soak TB exists |
| Quartus DCE of serializer | HIGH if not traced | outputs drive r/g/b/H*/V* when use_ext |
| Claiming 24/60 fps @ 20 MHz same-clock | **FORBIDDEN** | arithmetic: ≤20 Mpix/s out |

## 6) Pixel-rate vs fabric-rate (do not conflate)

| Quantity | 720p24 | 720p60 CEA |
|----------|--------|------------|
| Content Mpix/s | 22.118 | 55.296 |
| CEA Mpix/s | 29.70 | **74.25** |
| Fabric clk need @2ppc | 11.06 / 14.85 | 27.65 / **37.13 FAIL nostub** |
| Fabric clk need @4ppc | 5.53 / 7.43 | 13.82 / **18.56 OK @20** |
| **HDMI/CE out @ CE=1 same 20 MHz** | **≤20 Mpix/s** | **≤20 Mpix/s** |

4 ppc rescues **fabric** CEA720p60 work rate under 20 MHz. It does **not** emit
74.25 Mpix/s on a 20 MHz `CE_PIXEL`. Real 60 Hz glass needs **`clk_pix` ≥ 74.25 MHz**
(or HDMI ascal synthesizing 60 from a slower core — product decision, not proven here).
