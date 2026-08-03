# Decode-domain PLL feasibility envelope (no implementation)

**Lane:** w-clock · **No fit · No PLL edit · No domain built**  
**Why now:** w-scaler recon ≈ **34 cy/MB** (lower bound only). CAVLC still pending. Do **not** build a 50 MHz domain until that number lands. This is the decide-instantly card.

---

## Measured product PLL (quoted SoT)

`fpga/Plex_MiSTer/rtl/pll/pll_0002.v` (not stale `pll.v`):

| Param | Default product | With `PRESENT_CLK_PIX_PLL` |
|-------|-----------------|---------------------------|
| `reference_clock_frequency` | `"50.0 MHz"` | same |
| `fractional_vco_multiplier` | `"false"` | `"true"` |
| `number_of_clocks` | **3** | **4** |
| `operation_mode` | `"direct"` | same |
| out0 | **`"20.000000 MHz"`** → `clk_sys` | same |
| out1 | `MISTERPLEX_SDRAM_PLL_FREQ` (default **100 MHz**; macros 50–142) → `clk_sdram` | same |
| out2 | **`"90.000000 MHz"`** → `clk_ddr` | same |
| out3 | `"0 MHz"` (unwired) | **29.700** or **37.125** → `clk_pix` |
| out4…17 | `"0 MHz"` parameter slots | same; **not in `number_of_clocks`** |

`Plex.sv` instance: `.outclk_0(clk_sys) … .outclk_2(clk_ddr)`; optional `.outclk_3(clk_pix)`. Default: `wire clk_pix = clk_sys`.

**Beam / HDMI / ascal:** Route B keeps **pixel = clk_sys @ 20**. Separate **HDMI PLL** (`sys/pll_hdmi`) owns glass pixel rate — **do not retune product PLL out0/out2 for 720p glass**.

---

## Reachable decode clocks **without moving beam 20 or ddr 90**

Constraint: same altera_pll, keep `output_clock_frequency0/2` fixed. Add a **new** C-counter (raise `number_of_clocks` by 1; prefer **out4** if out3 is reserved for PIX, else out3 when PIX off).

### Integer-N family (default `fractional=false`)

20 and 90 force \(f_\mathrm{vco}=180k\) Hz with \(C_0=9k\), \(C_2=2k\).  
Prior STA network class used **VCO ≈ 360 MHz** (\(k=2\): \(C_0=18\), \(C_2=4\)) — **inferred from 20/90 ratio + prior notes**, not re-measured this turn (no new fit).

| VCO | Integer \(f_\mathrm{dec}=VCO/C\) that coexist with 20+90 | Notes |
|----:|----------------------------------------------------------|-------|
| **360** (shipping-class) | **10,12,15,18,20,24,30,36,40,45,60,72,90,120,…** | **50 NOT integer** (360/50=7.2) |
| **900** (\(k=5\)) | above **plus 25,50,75,100,…** | Retunes VCO; still keeps 20+90 exact; **needs fit/STA** |

**Practical envelope (integer, beam untouched):**

| Target `clk_dec` | PLL-parameter reachable? | Cost |
|-----------------:|--------------------------|------|
| 24 / 30 / 36 / 40 / 45 MHz | Yes on VCO 360 class | +1 outclk; CDC |
| **50 MHz** | **Only if VCO→900 or fractional=true** | Not free on measured 360 class |
| 25 / 75 / 100 | VCO 900 or share/steal out1 policy | out1 is SDRAM today — do not steal without w-mem |

**Fractional mode** (already used when `PRESENT_CLK_PIX_PLL`): can synthesize awkward rates (29.7, 50.0, …) on one PLL with out0/2 held — **still a fit grant**, not free silicon.

### What is **not** in envelope

- Bumping **clk_sys** (beam) — Route A / present path; killed for native 720p beam.  
- Bumping **clk_ddr** 90 — HPS/f2sdram; out of lane.  
- Claiming **decode Fmax ≥ any of the above** — **UNKNOWN** until post-fit STA of real `h264_decode_top` on that domain. Stub-in whole-chip Fmax **23.46 MHz** (`8fdf440f` STA) is **dark stub MV cone**, not decode. Nostub **32.59** is empty-of-stub sys, not decode.

---

## CDC cost (order-of-magnitude, design — not implemented)

Today decode sits on **clk_sys**; product frame pixels are **ARM→HPS DDR→`ddr_frame_store` @ clk_ddr**; fabric `fs_wr_*` dark under `DDR_FRAME_STORE`.

If a future `clk_dec` appears:

| Crossing | Need | Owner |
|----------|------|-------|
| bitstream / host cmd → dec | sync or FIFO into `clk_dec` | decode + top |
| dec MB/pixels → store | **async FIFO or req/ack into `clk_ddr` (or clk_sys dual-clock port)** | **w-mem** store/arbiter — w-clock does not edit |
| dec done / error → sys | 2FF or sticky status | top |
| reset/locked | hold dec in reset until `pll_locked` | top |

**CDC cost is real even if cy/MB never needs 50 MHz.** Prefer **stay on clk_sys @ 20** until CAVLC measurement proves a gap that integer 30–45 cannot close **and** STA of the decode cone allows it.

---

## Decision rule (for parent when CAVLC cy/MB lands)

Let \(B\) = budget cy/MB at domain f (e.g. 624×480@24 → \(20\times10^6/(1170\cdot24)=712\) @20 MHz; scale \(\propto f\)).  
Let \(C\) = measured full-decode cy/MB (CAVLC+recon+…; recon alone 34 is **not** \(C\)).

| Result | Action |
|--------|--------|
| \(C \le 712\) | **No decode PLL.** Stay clk_sys@20. |
| \(712 < C \le B(f^*)\) for some integer \(f^*\in\{24..45\}\) on VCO360 | Consider **one** spare outclk @ \(f^*\); STA gate; w-mem write CDC. |
| \(C > B(45)\) and only 50+ closes | Requires **VCO retune or fractional** + STA; still may need cy/MB diet. |
| Any claim without STA of dec cone | **UNKNOWN — fit is the check.** |

**No PLL strings applied. No domain built.**
