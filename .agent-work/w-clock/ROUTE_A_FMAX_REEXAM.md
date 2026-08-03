# Route A Fmax re-exam — was 23.46 a stub artifact?

**Lane:** w-clock · **No fit · No PLL apply · No device**  
**Question:** Did we kill native 1280×720 beam because of throwaway `decode_stub` timing?

---

## Pre-register (before re-reading reports)

| ID | Prediction | Score after |
|----|------------|-------------|
| P1 | 23.46 MHz Fmax path From/To is inside `decode_stub` | |
| P2 | Same report’s Fmax Summary line is general[0] = clk_sys | |
| P3 | Nostub fit Fmax general[0] is higher (~32.59 class) | |
| P4 | Module owning nostub 32.59 path is **named in a full path report** | |
| P5 | Min-blank native 720p@30 clk need ≤ 32.59 | |
| P6 | CEA 1650×750@30 clk need ≤ 32.59 | |

---

## 1. Source of **23.46 MHz** (MEASURED — quoted)

### Artifact A — full STA still on disk

**File:** `/home/flynnsbit/Projects/MisterPlex/fpga/Plex_MiSTer/remote_out/deploy2/Plex.sta.rpt`  
**RBF beside it:** `deploy2/Plex.rbf` md5 `8eb01b7965e25154eb4093bea16f1fc7`  
(docs also tag shipping-class **t7b / `8fdf440f`** for the same Fmax class; hash of *that* named RBF not re-verified this turn.)

**Fmax Summary (report lines 124–128):**

```text
; Fmax       ; Restricted Fmax ; Clock Name
; 23.46 MHz  ; 23.46 MHz       ; emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk
```

`general[0]` = product **clk_sys** (PLL out0 @ 20 MHz constrained).

### Critical path ownership (MEASURED)

From the same report family / extracted intra-sys dump  
`.agent-work/w-fit-1/clk_sys_intra_setup.txt` (and JOB1 mirror):

```text
Slack              ; 7.370
From Node          ; emu:emu|stream_path:spath|decode_stub:stub|lat_p_mb_addr[5]
To Node            ; emu:emu|stream_path:spath|decode_stub:stub|mv_col_al_x[7]
Launch = Latch     ; general[0] divclk  (clk_sys)
Setup Relationship ; 50.000 ns   (20 MHz period)
Data Delay         ; 42.333 ns
```

**Math (MEASURED inputs):**  
`Fmax = 1000 / (50.000 − 7.370) = 23.46 MHz` — matches Fmax Summary exactly.

**P1 HIT. P2 HIT.**

### What that module is

- Hierarchy: `stream_path:spath|decode_stub:stub|…`
- Under product `DDR_FRAME_STORE`, fabric stub write is **dark** (pixels = ARM→DDR). Stub is **placeholder / research cargo**, not the glass painter.
- RTL of the hog: comb `%`/`/` MV path in `decode_stub.sv` (documented in `PATH_CUT_lat_p_mb_addr_MV.md`).

**Explicit answer:**  
**Yes — the 23.46 MHz clk_sys Fmax is owned by `decode_stub` motion-vector logic, not by present/beam/scanout.**

---

## 2. Constraint **without** the stub (MEASURED + gap)

### Artifact B — nostub STA summary (on disk)

**File:**  
`/home/flynnsbit/Projects/MisterPlex/.worktrees/w-fit-integ/fpga/Plex_MiSTer/remote_out/fit-nostub-chrome/Plex.sta.rpt`  
Also scraped in `.agent-work/w-fit-1/post_fit_timing_nostub.log`.

**Fmax Summary L128 class:**

```text
; 32.59 MHz  ; 32.59 MHz  ; …general[0].gpll~PLL_OUTPUT_COUNTER|divclk   ;  # clk_sys
; 97.43 MHz  ; …general[2]…                                               ;  # clk_ddr
```

Setup slack @ **20 MHz** constraint on general[0]: **+0.982 ns** (summary).  
Worst chip setup in that fit is **+0.559** on **general[2] (clk_ddr)** — not the Fmax-sys story.

**P3 HIT** (23.46 → **32.59** when stub removed).

### Who owns the **32.59** path?

**UNKNOWN — report is summary-only (~1011 lines).**  
No `From Node` / `To Node` path panels in that `Plex.sta.rpt`.  
**P4 MISS.**

What would settle it:

```text
report_timing -setup -npaths 20 -detail full_path \
  -from_clock [get_clocks *general[0]*divclk] \
  -to_clock   [get_clocks *general[0]*divclk]
```

on the nostub (or current product-nostub) netlist — **parent fit grant**.

**INFERRED only (not authority):** removing stub raises Fmax by ~9 MHz; residual limiter is *some* remaining clk_sys logic (present, DDR reader side, bitstream, etc.) at **data-path order ~30.7 ns**. Do **not** treat 32.59 as “present_beam Fmax” without the path name.

---

## 3. Pixel clock a **native** 1280×720 beam actually needs

1ppc, clk_sys = pixel clock. Totals = H_TOTAL × V_TOTAL.  
**MEASURED arithmetic (awk); blanking choices are design, not STA.**

| Blanking geometry | H×V | Tot | fps @20 | **clk @24** | **clk @23.976** | **clk @30** | **clk @29.97** |
|-------------------|----:|----:|--------:|------------:|----------------:|------------:|---------------:|
| Beam min-pad style (H≥DE+32, V≥ACT+16) | **1312×736** | 965632 | 20.71 | **23.175** | 23.152 | **28.969** | 28.940 |
| Tight “sane” | **1344×750** | 1008000 | 19.84 | **24.192** | 24.168 | **30.240** | 30.210 |
| CEA-861 720p | **1650×750** | 1237500 | 16.16 | **29.700** | 29.670 | **37.125** | 37.088 |

Parent’s **30.24 MHz** = **1344×750×30** (tight@30).  
Min-blank@30 is **28.97 MHz** — slightly easier.

### vs measured Fmax

| Need | vs stub-in **23.46** | vs nostub **32.59** | vs integer PLL **30** | vs integer PLL **36** |
|------|---------------------:|--------------------:|----------------------:|----------------------:|
| 23.18 (min@24) | FAIL | OK (+9.4) | OK | OK |
| 24.19 (tight@24) | FAIL | OK (+8.4) | OK | OK |
| 28.97 (min@30) | FAIL | OK (+3.6) | OK (+1.0 vs need; **Fmax margin +3.6**) | OK |
| 30.24 (tight@30) | FAIL | OK (+2.35) | **short 0.24** vs PLL 30 | OK (+5.76 vs need; Fmax +2.35) |
| 29.70 (CEA@24) | FAIL | OK (+2.9) | OK | OK |
| 37.13 (CEA@30) | FAIL | **FAIL (−4.5)** | FAIL | **FAIL (−1.1)** |

**P5 HIT** (min-blank@30 ≤ 32.59). **P6 MISS** (CEA@30 > 32.59).

PLL envelope (prior, integer VCO360, beam out0 retune is a **sys** bump not spare dec): **30 and 36 MHz are parameter-reachable** as *sys* targets only with a **new fit**; they are not free.

---

## 4. Verdict — reopen or stay dead?

### What was wrong in the closed kill

| Claim used to kill Route A | Status |
|----------------------------|--------|
| “Fmax is 23.46 so 30.24 is impossible” | **True only on stub-in netlists** where Fmax is **`decode_stub` MV** |
| “23.46 is the present/beam ceiling” | **FALSE** — path From/To are stub registers |

**Unforced-error class:** treating **cargo timing** as **product present ceiling**.  
The number was real; the **scope** was wrong for a nostub/product-no-stub world.

### What is still true (do not over-swing)

1. **Stub-in shipping-class RBFs:** Route A @ ≥23.2 MHz still **STA-dead** until stub is out or path-cut.  
2. **Nostub Fmax 32.59** is MEASURED on **fit-nostub-chrome**, which is **empty-of-stub present path**, **not** a fitted native-720p-beam + clk_sys@30 design. Adding 1280 DE, wider line buffers, multi-pixel, or PLL bump **can move Fmax** — **UNKNOWN until that fit**.  
3. **CEA 720p30 timing on core beam** still **fails** 32.59 even on paper (**37.12**). Native beam would use **reduced blanking** (min-pad / tight), with ascal/HDMI still free to run CEA on **pll_hdmi**.  
4. **clk_sys → 30 MHz** tightens **related-edge CDC** to clk_ddr 90 (period family 3:1). Prior analysis flagged this; **slack UNKNOWN** until STA.  
5. **Route B remains correct** for “720p on glass” **without** overclock. Route A is “720p in the core DE,” a stricter product claim.

### Decision table (honest)

| Goal | On stub-in (Fmax 23.46) | On nostub paper (Fmax 32.59) | Proven on silicon/STA? |
|------|-------------------------|------------------------------|------------------------|
| Native 720p24 min/tight blank | Dead | **Plausible** (need ~23.2–24.2) | **NO** — no 24–30 MHz sys fit |
| Native 720p30 min-blank | Dead | **Plausible** (need ~28.97; margin ~3.6) | **NO** |
| Native 720p30 tight 30.24 | Dead | **Plausible** if sys≥30.24; integer **30 short**; **36** covers | **NO** |
| Native CEA 720p30 | Dead | **Still dead** (37.12 > 32.59) | N/A |

**Route A status after re-exam:**

- **Kill of “impossible forever because 23.46” — WITHDRAWN** for **nostub / no-stub product**.  
- **Kill of “ship native 720p beam tomorrow” — STANDS** (no STA at target clock; no native-720p netlist Fmax; CEA30 still dead; CDC unproven).  
- **Conditional reopen:** worth a **parent-granted** experiment only after product is **PRODUCT_NO_STUB** (or equivalent), with pre-registered gates:

```text
PRE-REG gates for any Route A fit (parent only):
  G1 clk_sys Fmax ≥ 30.24 (tight30) or ≥ 28.97 (min30) — quote STA
  G2 same-clock path From/To NOT decode_stub (must be named)
  G3 setup slack ≥ 0 on clk_sys @ chosen period
  G4 related clk_sys↔clk_ddr setup slack ≥ 0 (no false-path cheat)
  G5 post-fit hierarchy: present_beam survives; DE 1280 path real
  G6 NEW_RBF ∉ banned set
HIT if all; MISS if any fail — Route A stays lab-dead.
```

**Recommended product default until G1–G6:** keep **Route B** (content DE ≤960×540 @20 MHz, ascal → 1280×720 glass).

---

## 5. MEASURED vs INFERRED (fence)

| Item | Class | Source |
|------|-------|--------|
| Fmax 23.46 on general[0] | **MEASURED** | `deploy2/Plex.sta.rpt` L128 |
| Path lat_p_mb_addr→mv_col_al_x in decode_stub | **MEASURED** | same report / `clk_sys_intra_setup.txt` |
| Data delay 42.333, slack 7.370 @ 50 ns | **MEASURED** | same |
| Fmax 32.59 nostub general[0] | **MEASURED** | `fit-nostub-chrome/Plex.sta.rpt` + `post_fit_timing_nostub.log` |
| Module owning 32.59 path | **UNKNOWN** | summary STA only |
| clk need table for 1312×736 / 1344×750 / 1650×750 | **ARITHMETIC** (exact) | awk; not STA |
| “Present alone meets 30 MHz” | **INFERRED** — forbidden as fact | needs G1–G2 fit |
| CDC OK at 30/90 | **UNKNOWN** | needs G4 |
| Route B still works without OC | **prior measured architecture** | ascal Route B (unchanged) |

---

## Bottom line (one paragraph)

**The 23.46 MHz figure is real and is owned by `decode_stub` (`lat_p_mb_addr` → `mv_col_al_x`), not the beam.** Killing native 720p *solely* with that number was a **scope error** once the product drops the stub: nostub **clk_sys Fmax 32.59 MHz** leaves **paper margin** for min-blank or tight **720p24 and 720p30** (not CEA720p30). That does **not** resurrect Route A as proven — only as **conditionally reopened pending a nostub fit at the target clk_sys with named paths and CDC slack.** Until then Route B remains the honest 720p-on-glass path; B20 stays open on DAR/Plex.
