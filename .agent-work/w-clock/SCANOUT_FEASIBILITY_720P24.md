# 720p24 scan-out feasibility vs measured STA Fmax

**Lane:** w-clock · **No fit · No device**  
**Fmax evidence (re-parsed STA):** stub-in `8fdf440f` **23.46 MHz** · nostub `c74c6863` **32.59 MHz** · shipping PLL **20.0 MHz**  
**RTL:** `ce_pix=1` under `PRODUCT_V_480` → **1 pixel per clk_sys** (`colorbars.sv`, `Plex.sv` `CLK_VIDEO=clk_sys`).

Parent measurement (device): ARM 720p decode alone = **41.073 ms/f** (98.6% of 41.667 ms budget).  
Non-decode must leave ARM. This note answers only: **can clk_sys clock a 720p raster / touch 720p24 pixels?**

---

## 1) The number that gates the programme

| Quantity | Arithmetic | Value |
|----------|------------|------:|
| 720p24 content pixels/sec | 1280 × 720 × 24 | **22.118 Mpix/s** |
| 480p24 content (640×480) | 640 × 480 × 24 | 7.373 Mpix/s |
| Ratio | 22.118 / 7.373 | **3.00×** (coded 624×480 → 3.08×) |
| Shipping clk_sys | PLL out0 | **20.000 MHz** |
| **22.118 ≟ 20** | content touch @ 1 px/clk | **22.118 > 20 → HARD MISS** |

**Verdict A — content touch rate (1 clk per content pixel per frame, lower bound):**  
At **shipping 20 MHz**, the fabric **cannot visit every 1280×720 pixel once per 24 Hz frame**.  
Blanking cannot fix this: blanking only *reduces* useful pixel slots.  
This is independent of HDMI `video_mode` (ascal). It is pure clk_sys × 1 ppc.

| clk_sys / Fmax | 22.118 Mpix/s fit? | Utilisation | Note |
|----------------|--------------------|------------:|------|
| 20.00 ship | **NO** | 110.6% | Programme-dead for native 720p24 1ppc touch |
| 23.46 stub Fmax | **YES thin** | 94.3% | ≤Fmax but **cannot ship stub** if constrained period must be ≥22.12 ns... wait: Fmax 23.46 means period can be 42.6 ns → 23.46 MHz max *achievable*; operating *at* 22.12 MHz would need PLL ~22.12 and STA pass. Stub Fmax 23.46 > 22.12 → paper OK if PLL set ~22.5 and paths close. **Still fails other rasters below.** |
| 32.59 nostub Fmax | **YES** | 67.9% | Headroom for blanking + overhead |

So: **nostub is mandatory** for native 720p24 pixel touch. Shipping 20 MHz is not a near-miss; it is over-subscribed.

---

## 2) Full raster pixel clocks (1 px/clk) vs Fmax

Raster need = `H_TOTAL × V_TOTAL × f_display` (MHz at 1 ppc).

| Raster (1 px/clk) | Mpix/s = need MHz | vs 20 ship | vs 23.46 stub | vs 32.59 nostub |
|-------------------|------------------:|:----------:|:-------------:|:---------------:|
| Today Template 638×524@60 | 20.059 | FAIL\* | OK | OK |
| **M1** 720-line 638×750@60 | **28.710** | FAIL | **FAIL** | **OK** |
| **M1** 638×786@60 | **30.088** | FAIL | FAIL | OK thin |
| **M2 CEA** 1650×750@60 | **74.250** | FAIL | FAIL | **WALL** |
| M2 scaled-porch 1544×750@60 | 69.480 | FAIL | FAIL | **WALL** |
| M2 CEA 1650×750@30 | 37.125 | FAIL | FAIL | **WALL** |
| **M2 CEA 1650×750@24** | **29.700** | FAIL | FAIL | **OK** |
| M1 638×750@24 | 11.484 | OK | OK | OK |

\*Today runs at 20 MHz constrained; Fmax 23.46 means STA closed with small margin — table “vs 20” is constrained rate vs need, not Fmax.

### Scan-out verdicts (1 ppc)

| Goal | Stub Fmax 23.46 | Nostub Fmax 32.59 | Ship 20 MHz |
|------|-----------------|-------------------|-------------|
| Native **1280×720@60** raster | WALL | WALL | WALL |
| Native **1280×720@24** CEA raster | FAIL (29.7>23.46) | **OK** (29.7<32.59) | FAIL |
| **720-line** DE, keep H=638, **@60** (M1) | FAIL | **OK** (~28.7–30.1) | FAIL |
| 720p24 **content touch** only | thin/OK at ~22.2 PLL | OK | **FAIL 22.1>20** |
| Scale 720p store into 529-DE @60 (M0) | OK | OK | OK but **not native 720p scan-out** |

**Parent question — “if clk_sys cannot clock out a 720p raster, the programme dies”:**  
- **720p@60 1ppc raster: dies on this silicon Fmax** without multi-pixel datapath.  
- **720p@24 1ppc CEA raster: lives only on nostub + PLL ~30 MHz + STA.**  
- **720p24 content touch: dies at 20 MHz; lives on nostub ≥ ~23+ MHz constrained.**

MiSTer output HDMI can still be 720p60 via `video_mode` while core DE is slower — that is **ascal**, not core scan-out of 1280 unique pixels/line.

---

## 3) Multi-pixel escape (mandate: ARM-out present, not eternal M0)

For CEA 74.25 MHz pixel rate @60:

| px/clk | clk_sys need | stub 23.46 | nostub 32.59 |
|-------:|-------------:|:----------:|:------------:|
| 1 | 74.25 | FAIL | FAIL |
| 2 | 37.13 | FAIL | FAIL |
| **3** | **24.75** | FAIL | **OK** |
| **4** | **18.56** | **OK** | OK |

**Recommendation:** size present/linebuf path for **≥3 px/clk (prefer 4)** and **CODED_W=1280** from day one (1280 B luma line = one M10K). Then 720p60 glass does not depend on a fantasy 74 MHz clk_sys.

Target **B 30/90** still preferred for: fabric-decode cy/MB, M1@60, CEA@24 1ppc, and CDC 3:1.

---

## 4) Assumptions invalidated by parent 41.073 ms/f measurement

| Prior assumption | Status |
|------------------|--------|
| “ARM might keep some non-decode work at 720p” | **Invalidated** — decode alone is 98.6% of budget; 0.59 ms margin |
| 1080p synthetic 32.4 ms/f as planning anchor | **Superseded** — use **41.073 ms/f** real 720p@4 Mb/s |
| cy/MB-only 25 MHz story as primary clock driver | **Incomplete** — **scan-out 22.12 Mpix/s > 20 MHz** is an equal hard gate |
| M0 “no bump needed” as comfortable fallback | **Invalid as programme plan** — does not clock out 720p pixels; leaves ARM/scale path |

---

## 5) LANDED (this lane) · blocker

**Landed:** `w-clock-bump` commits `e86913cb` + `81b64223` — PLL contract gate, SDC comments, CDC ratio audit, proposal; **PLL still 20/90 (not applied)**.

**Blocker parent can clear:** exclusive **nostub product STA** then **one fit grant for B_30_90** (or multi-pixel present RTL + fit). Without nostub Fmax class ≥30, 720p scan-out and fabric-decode 720p24 both stay paper.
