# 720p pixel clock + DDR bandwidth (w-clock)

**MEASURE_REF:** `w-clock-720p-clk` on main `8fb5afe7`  
`git rev-parse --abbrev-ref HEAD` + `git rev-parse HEAD` quoted at commit time.  
No Quartus fit by w-clock. No device.

---

## 1. CEA / VESA pixel clocks (exact arithmetic)

Blanking from CEA-861 (also encoded in `present_video_timing_720p.sv` /
`present_beam_ppc` parameters H_TOTAL=1650 V_TOTAL=750 for the pack path).

| Mode | Standard | H_TOTAL | V_TOTAL | fps | Arithmetic | f_pix |
|---|---|---:|---:|---:|---|---:|
| 720p60 | CEA-861 **VIC 4** | 1650 | 750 | 60 | 1650×750×60 = **74_250_000** | **74.25 MHz** |
| 720p24 | CEA-861 **VIC 60** | 3300 | 750 | 24 | 3300×750×24 = **59_400_000** | **59.40 MHz** |
| 720p24 pack | VIC4 totals @24 (non-VIC) | 1650 | 750 | 24 | 1650×750×24 = **29_700_000** | **29.70 MHz** |

PIX_PER_FRAME (pack) = 1650×750 = **1_237_500**.

**Not CEA:** active-only 1280×720×24 = 22_118_400 Hz — rejected by unit test.

L4 content beam (separate path, `DDR_FRAME_720P24_BEAM_*`): H=1312 V=762  
→ 1312×762×24 = 23_993_856 Hz ≈ **24.00 MHz** content raster (ascal still owns glass).

---

## 2. Current PLL (quoted SoT)

File: `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` (wrapper `rtl/pll.v` is not SoT).

| out | name | frequency string | product default |
|---|---|---|---|
| 0 | clk_sys | `"20.000000 MHz"` | YES |
| 1 | clk_sdram | `MISTERPLEX_SDRAM_PLL_FREQ` (QSF `SDRAM_CLK_142` → 142 MHz) | YES |
| 2 | clk_ddr | `"90.000000 MHz"` | YES |
| 3 | clk_pix | `"29.700000 MHz"` or `"74.250000 MHz"` | **NO** — `PRESENT_CLK_PIX_PLL` only |

Ref: `reference_clock_frequency("50.0 MHz")`.  
`Plex.sv` product: `.clk_pix(clk_sys)`; flag on: `.clk_pix(clk_pix_pll)` ← outclk_3.

---

## 3. DDR read bandwidth (product format = YUV420p / I420)

Source: `ddr_frame_store.sv` header + `ddr_frame_layout_params.svh`:
`DDR_FRAME_720P_YUV420P_BYTES = 1382400` (= 1280×720×3/2).

| fps | bytes/frame | FPGA read (MB/s, 10^6) | ARM write (model=same) | Total fabric |
|---:|---:|---:|---:|---:|
| 24 | 1_382_400 | **33.1776** | 33.1776 | 66.3552 |
| 60 | 1_382_400 | **82.944** | 82.944 | 165.888 |

### DE10-Nano HPS DDR budget (in-repo model)

From `docs/display-resolution.md` (MEASURED project model, not a new guess):

- DDRAM port 64-bit @ `clk_ddr` → peak = f_ddr × 8 bytes  
- Product `clk_ddr` = **90 MHz** → peak = **720 MB/s**  
- Pessimistic FPGA-read budget = **25% × peak = 180 MB/s** (room for ARM, Linux, ascal, decode)

| Mode | FPGA read | vs 180 MB/s budget | Verdict |
|---|---:|---|---|
| 720p24 YUV420p | 33.18 | 18% of budget | **FITS** |
| 720p60 YUV420p | 82.94 | 46% of budget | **FITS** |
| 720p60 RGB565 | 110.59 | 61% of budget | FITS by BW (not product format) |

**Negative / wall:** if someone treated DDRAM as 20 MHz (confusing clk_sys with clk_ddr),  
budget = 40 MB/s and **720p60 YUV420p 82.94 does NOT fit**. Product DDR is 90 MHz — do not confuse.

Latency/prefetch (docs): 720p class needs 16-line prefetch under 500 µs blackout model — bandwidth FIT ≠ latency FIT. Prefetch is w-mem/store lane; flagged here only.

---

## 4. PLL change (default-OFF RTL)

| Macro | Effect |
|---|---|
| `PRESENT_CLK_PIX_PLL=1` | `number_of_clocks(4)`, out3 = 29.70 MHz, wire `clk_pix` |
| `PRESENT_CLK_PIX_74_25=1` | out3 = 74.25 MHz (with above) |
| `Plex_clk_pix.sdc` | async clock groups clk_pix ⊥ clk_sys / clk_ddr |

QSF recipe is **commented**. Product build unchanged (3-clock PLL).

### Throughput coupling (hard)

`present_npx_path`: peak fabric Mpix/s into FIFO = `F_sys × PPC`.  
Unpack rate on clk_pix must be sustained long-term.

| clk_sys | PPC | fabric Mpix/s | vs 29.70 | vs 74.25 |
|---:|---:|---:|---|---|
| 20 | 1 | 20.0 | **FAIL** | FAIL |
| 20 | 2 | 40.0 | PASS | FAIL |
| 20 | 4 | 80.0 | PASS | PASS |

Land today forces `PRESENT_PX_PER_CLK=1` until `ddr_frame_store` grows N-wide RGB.  
**So enabling clk_pix=29.7 alone is not sufficient for MULTI_PIXEL land** without PPC≥2 or moving the beam onto clk_pix. L4 path (1312×762) targets ~24 MHz content beam, not CEA 74.25 glass.

---

## 5. CDC (new clk_pix)

| # | Crossing | Direction | Width | Protection | Status |
|---|---|---|---|---|---|
| P1 | `present_npx_path` group FIFO | clk_sys → clk_pix | group bus | `async_fifo` gray ptrs | SAFE (existing) |
| P2 | `prefill_go` | clk_sys → clk_pix | 1 | 2FF | SAFE (existing) |
| P3 | `reset` → pix | async assert | 1 | 2FF `mp_rst_pix*` when flag on | SAFE |
| P4 | CE_PIXEL / RGB out | clk_pix domain | — | same domain to core video outs when MULTI_PIXEL | OK |
| P5 | ddr_frame_store rd | clk_sys / clk_ddr | — | **unchanged**; still inventory rows B1–B3 | existing |

SDC (`Plex_clk_pix.sdc`): `set_clock_groups -asynchronous` between clk_pix and clk_sys, and clk_pix and clk_ddr.  
**No** false_path on residual_csum. Unsynchronised multi-bit without FIFO = hard fail — none introduced.

---

## 6. PRE-REGISTER (timing) — see `720P_CLK_PREREG.md`
