# CLK_PIX PLL plan — separate pixel clock (not a clk_sys bump)

**Branch:** `w-clock-bump`  
**Status:** **LANDED_IFDEF_DEFAULT_OFF** — PIX24 strings live under `PRESENT_CLK_PIX_PLL`;
default (macro unset) stays 3-clock 20/90 shipping. Product QSF still OFF until fit grant.  
**Macro default:** `PRESENT_MULTI_PIXEL` OFF; new `PRESENT_CLK_PIX_PLL` OFF.

Parent direction (2026-08-03): design `clk_pix` (~29.7 MHz 720p24 CEA, 74.25 MHz 720p60) as a **separate PLL output**, not a `clk_sys` overclock. Full fabric H.264 is multi-month; present/scale/idle + DMA remains the near-term path.

### Output vs source (parent measurement — do not conflate)

Parent 300-frame probes (device clean): ARM **decode+copy** of true 1280×720 source **FAILS**. Fabric raster and source resolution are **independent**.

**Standing product target (parent, all measured, includes sws/rawvideo):**
```
PMS  → Constrained Baseline 960×540 (videoProfile=baseline pinned)
ARM  → decode+sws+copy = 26.08 + 8.42 = 34.50 ms vs 41.667  margin +7.16 PASS
FABRIC → upscale 960×540 → native 1280×720 glass (w-scaler 1.333×)
```
Prior decode-only 960 margin +10.49 was optimistic by 3.33 ms (parent corrected).  
ARM downscale from fetched 720p is **FAIL** (51.78–60.20 ms class) — not a fallback.

**`clk_pix` remains the gate for true CEA 24 Hz on glass** — sizes the **output** raster (1650×750×fps), not the source. Without PIX24 @29.7, core max is ~16.16 Hz at CEA totals.

---

## 1) Why this bump (and why not clk_sys)

| Fact | Value | Source |
|------|------:|--------|
| Shipping `clk_sys` | **20.000 MHz** | `pll_0002.v` `output_clock_frequency0` |
| Shipping `clk_ddr` | **90.000 MHz** | `output_clock_frequency2` |
| Multi-pixel today | `clk_pix` **tied to `clk`** | `present_core.sv` `u_mp_npx_path.clk_pix(clk)` |
| MiSTer out | `CLK_VIDEO = clk_sys`, `CE_PIXEL = ce_pix` | `Plex.sv` L849–850 |
| One RGB / CE | output ≤ f(CLK_VIDEO) when CE=1 | MiSTer contract |
| Same-clock cap | **≤ 20 Mpix/s** ≈ **16.16 Hz** @ 1650×750 | `20e6 / 1_237_500` |
| CEA 720p24 need | **29.70 Mpix/s** | 1650×750×24 |
| CEA 720p60 need | **74.25 Mpix/s** | 1650×750×60 |
| Fabric work @2ppc 24 | **11.06–14.85 MHz** | headroom doc — **under 20** |
| Fabric work @4ppc 60 | **18.56 MHz** | headroom doc — **under 20** |

**Conclusion:** `clk_sys` already covers **fabric** work at PPC≥2/4. The silent blocker is **scan-out rate**. Fix = faster **`clk_pix` / `CLK_VIDEO`**, leave **`clk_sys` at 20** and **`clk_ddr` at 90**.

Do **not** bump `clk_sys` to 29.7/74.25 — that would fail Fmax (nostub ~32, stub ~23; 74 is a wall), destroy sys↔ddr related-edge margin, and burn fabric timing for a pixel-sink problem.

---

## 2) Target frequencies (exact)

```
PIX_PER_FRAME = 1650 × 750 = 1_237_500
f_pix_24 = 24 × 1_237_500 = 29_700_000 Hz
f_pix_60 = 60 × 1_237_500 = 74_250_000 Hz
```

| Target ID | `clk_pix` | Refresh @ CEA totals | Use |
|-----------|----------:|---------------------:|-----|
| **PIX24** | **29.700000 MHz** | **24.000 Hz** | First justified apply (**this fit**) |
| **PIX24i** | 30.000000 MHz | 24.242 Hz (~+1%) | Integer-PLL interim if fractional blocked |
| **PIX30** | **37.125000 MHz** | **30.000 Hz** | TV/30 content glass; PPC≥2; **not this fit** |
| **PIX60** | **74.250000 MHz** | **60.000 Hz** | Stretch; needs PPC=4 + STA |

Multi-rate ARM budget: `CONTENT_FPS_CADENCE_AND_CLK_PIX.md` (960@30 fails 34.50 vs 33.33).

---

## 3) PLL parameter strings (in tree under `PRESENT_CLK_PIX_PLL`)

**SoT when granted:** `fpga/Plex_MiSTer/rtl/pll/pll_0002.v`  
**Wrapper:** `fpga/Plex_MiSTer/rtl/pll.v` must grow `outclk_3`.  
**Do not edit stale megawizard comment strings as SoT.**

### 3.1 PIX24 (preferred first grant)

Keep outs 0–2. Add clock 3. Prefer **fractional** VCO (same family as `pll_hdmi_0002` @ 148.5 MHz from 50 MHz ref — proves the part can synthesize CEA family rates).

```verilog
// Landed under `ifdef PRESENT_CLK_PIX_PLL in pll_0002.v (default OFF)
.fractional_vco_multiplier("true"),   // was "false"; required for exact 29.7
.reference_clock_frequency("50.0 MHz"),
.number_of_clocks(4),                 // was 3
.output_clock_frequency0("20.000000 MHz"),  // clk_sys UNCHANGED
.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ), // unchanged
.output_clock_frequency2("90.000000 MHz"),  // clk_ddr UNCHANGED
.output_clock_frequency3("29.700000 MHz"),  // NEW clk_pix
.phase_shift3("0 ps"),
.duty_cycle3(50),
```

`altera_pll_i.outclk` packing becomes `{outclk_3, outclk_2, outclk_1, outclk_0}`.

**Legal M/N/C:** exact counter fields are **unknown until** Quartus `altera_pll` accepts the frequency string (HDMI path already locks 148.5 fractional from 50 MHz on this board). Gate checks the *string intent*; parent fit is the legal-IP proof. Do not hand-invent counter bits.

### 3.2 PIX24i (integer interim)

If fractional on the **product** PLL is rejected by fit/IP policy:

```verilog
.fractional_vco_multiplier("false"),  // keep integer-N
.number_of_clocks(4),
.output_clock_frequency0("20.000000 MHz"),
.output_clock_frequency2("90.000000 MHz"),
.output_clock_frequency3("30.000000 MHz"),  // 50×3/5 class
```

fps_eff = 30e6/1_237_500 ≈ **24.24 Hz** (+1% vs CEA 24). Better than 16.16 Hz same-clock.

### 3.3 PIX30 (after multi-rate product decision — not this fit)

```verilog
.output_clock_frequency3("37.125000 MHz"),  // 1650*750*30
```

Fabric: PPC≥2 → 40 Mpix/s ≥ 37.125 at clk_sys=20. STA: Fmax_pix≥37.125.  
Prefer fps-aware ladder / PMS fps policy before retargeting glass — see cadence doc.

### 3.4 PIX60 (second grant — after PIX24 STA green)

```verilog
.fractional_vco_multiplier("true"),
.number_of_clocks(4),
.output_clock_frequency0("20.000000 MHz"),
.output_clock_frequency2("90.000000 MHz"),
.output_clock_frequency3("74.250000 MHz"),  // NEW clk_pix @60
```

Not simultaneous dual 29.7+74.25 without reconfig; mode is build/define or PLL reconfig (optional later).

### 3.5 Explicit non-goals

| Change | Allowed? |
|--------|:--------:|
| Raise `output_clock_frequency0` (clk_sys) | **NO** for this plan |
| Raise `output_clock_frequency2` (clk_ddr) | **NO** |
| Raise HPS/DDR3 hard-IP | **NO** |
| Ship PLL edit with macros at reset | **NO** — bit-identical `d1b24e0c` when OFF |

---

## 4) Rate balance (fabric write vs pixel drain)

`present_npx_path`: N-wide @ `clk_sys` → async_fifo → 1 px/clk @ `clk_pix`.

```
peak_fabric_mpix = f_sys × PPC
need_out_mpix    = f_pix
```

| Mode | f_pix | PPC | peak fabric @20 | Sustained OK? |
|------|------:|----:|----------------:|:-------------:|
| 720p24 | 29.70 | 1 | 20.0 | **NO** (starves) |
| 720p24 | 29.70 | **2** | 40.0 | **YES** (margin 1.35×) |
| 720p24 | 29.70 | 4 | 80.0 | YES |
| 720p60 | 74.25 | 2 | 40.0 | **NO** |
| 720p60 | 74.25 | **4** | 80.0 | **YES** (margin 1.08×) |

**Hard couple:** PIX24 ⇒ `PRESENT_PX_PER_CLK >= 2`; PIX60 ⇒ `PRESENT_PX_PER_CLK >= 4`.

Blanking ~22% is catch-up only — do not use it to excuse PPC=1@29.7.  
At PIX60 margin 1.08×, FIFO depth + `in_ready` backpressure are load-bearing.

---

## 5) Wiring plan (gated — default OFF)

### 5.1 Macros

| Macro | Default | Effect |
|-------|---------|--------|
| `PRESENT_MULTI_PIXEL` | **OFF** | N-wide + 720p beam |
| `PRESENT_PX_PER_CLK` | 2 (when multi on) | 2 or 4 |
| `PRESENT_CLK_PIX_PLL` | **OFF** | `outclk_3` → `clk_pix` / `CLK_VIDEO` |

When multi ON && !CLK_PIX_PLL: keep `clk_pix=clk` (Stage 0 geometry @ ~16 Hz core).  
When both ON: split domains (true 24/60 Hz core raster).

### 5.2 `pll.v` / `pll_0002.v` (grant only)

```verilog
output wire outclk_3  // clk_pix
```

### 5.3 `Plex.sv` (grant only, under ifdef)

```verilog
wire clk_pix;
pll pll (
  .outclk_0(clk_sys),
  .outclk_1(clk_sdram),
  .outclk_2(clk_ddr),
`ifdef PRESENT_CLK_PIX_PLL
  .outclk_3(clk_pix),
`endif
  .locked(pll_locked)
);

`ifdef PRESENT_CLK_PIX_PLL
  assign CLK_VIDEO = clk_pix;
  assign CE_PIXEL  = 1'b1;   // true pixel clock
`else
  assign CLK_VIDEO = clk_sys;
  assign CE_PIXEL  = ce_pix; // shipping UNCHANGED
`endif
```

Pass `clk_pix` into `present_core` (optional port; default tie to `clk` when OFF).

### 5.4 `present_core.sv`

Today: `.clk_pix(clk)`. On grant: `.clk_pix(clk_pix_i)` and `CLK_PIX_HZ` = 29_700_000 / 74_250_000.

Beam stays on **`clk_sys`**. Serializer drain on **`clk_pix`**.  
**Open at apply:** HS/VS/DE must share the pixel domain or cross with pixel-aligned sideband — bare 2FF sync without DE alignment tears. Same-clock bring-up hides this; Stage 1 must implement it explicitly.

---

## 6) CDC contract (extends `e0f23e5a`)

| Crossing | Protection today | When clk_pix splits |
|----------|------------------|---------------------|
| async_fifo gray wr↔rd | gray + 2FF | **unchanged — load-bearing** |
| async_fifo `mem → rd_data_r` | `Plex.sdc` false_path | **unchanged — only proven cut** |
| Bare RGB/HS without FIFO | forbidden | still forbidden |
| Whole `clk_sys`↔`clk_pix` false_path | **forbidden** | still forbidden |
| Related-edge sys↔ddr 5.556 ns | shipping | **unchanged** (sys still 20) |

```bash
make post-fit-timing STA_RPT=...
# clk_pix Fmax ≥ 29.7 (PIX24) or ≥ 74.25 (PIX60)
# clk_sys ≥ 20 with multi-pixel ON
```

**Unknown until fit:** multi-pixel Fmax @20; clk_pix cone @29.7/74.25.  
If clk_pix Fmax < target → pipeline path, **not** false_path.

---

## 7) MiSTer HDMI / lab

- Parent `video_mode=0` (1280×720@60); bak restore `8`.
- HDMI PLL (`pll_hdmi` ~148.5) independent of product PLL.
- 24 Hz core into 60 Hz sink ⇒ ascal policy is parent-observed.
- PIX60 aligns core with 720p60 sink.
- Scandoubler **off** for progressive 720p when CE=1 @ pix clock.
- Control arm: `CYAN_PX=0`, `ACTIVE=923x717` on `d1b24e0c`.

---

## 8) Staged apply (parent-owned fits)

| Stage | Config | Goal |
|------:|--------|------|
| **0** (now) | multi-pixel ON, clk_pix=clk, PLL ship | Geometry 1280×720 DE ~16 Hz |
| **1** | PLL PIX24 29.7, `PRESENT_CLK_PIX_PLL`, PPC≥2 | True ~24 Hz core |
| **2** | PLL PIX60 74.25, PPC=4 | True 60 Hz core |
| — | clk_sys bump | **Not in this plan** |

Stage 0 is the queued integration fit. This doc unblocks Stage 1 design without the exclusive slot.

---

## 9) Applied vs proposed

| Item | State |
|------|--------|
| This plan + contract + gate | **APPLIED** (docs/scripts) |
| `present_core.clk_pix` port + `clk_pix(clk_pix)` npx | **APPLIED** (default tie `clk_pix=clk_sys`) |
| `present_pix_rate_match` Bresenham | **APPLIED** (instantiated only under `PRESENT_CLK_PIX_PLL`) |
| `present_npx_path` INCLUDE_SYNC sideband + blank inject | **APPLIED** (INCLUDE_SYNC=0 default) |
| `Plex.sv` CLK_VIDEO mux under `PRESENT_CLK_PIX_PLL` | **APPLIED** (macro OFF → ship path) |
| `pll_0002.v` outclk_3 @ 29.7 | **LANDED under ifdef** (default 3-clk shipping) |
| `pll.v` / `Plex.sv` `.outclk_3(clk_pix)` | **LANDED under ifdef** (no placeholder when ON) |
| `PRESENT_CLK_PIX_PLL` product QSF | **NOT applied** (must stay OFF for bit-identical) |
| SDC clk_pix comment block | **APPLIED** (comments) |
| Claim 24/60 Hz on glass | **FORBIDDEN** until STA + capture with macro ON |

---

## 10) Parent commands

```bash
make fabric-clock-headroom
python3 scripts/check_clk_pix_pll_plan.py --root .
./tests/unit/test_clk_pix_pll_plan.sh; echo "true rc=$?"

# After Stage-1 fit (parent only)
make post-fit-timing STA_RPT=path/to/Plex.sta.rpt
make post-fit-hierarchy FIT_RPT=path/to/Plex.fit.rpt
scripts/hdmi_capture_idle.sh /path/to/cap.png
```

---

## 11) Bottom line

**Justified bump = `clk_pix` @ 29.7 (then 74.25), separate PLL output; `clk_sys` stays 20.**  
PPC≥2 (24) / PPC≥4 (60) for FIFO balance. CDC = async_fifo only.  
No product PLL edit until parent grants the fit.
