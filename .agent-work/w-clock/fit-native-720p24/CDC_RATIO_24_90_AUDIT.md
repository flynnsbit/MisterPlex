# CDC ratio audit: clk_sys 20→24 MHz (4:15 vs clk_ddr 90)

**HEAD_BRANCH:** w-clock-bump  
**HEAD_SHA:** (see commit)  
**MEASURE_REF source tree:** this branch tip; inventory `docs/cdc-crossing-inventory.md`  
**PLL edit:** NOT applied  

## Executive verdict

| Question | Answer |
|----------|--------|
| Is 24/90 safe by construction for **related-edge STA** paths? | **NO — BLOCKER class for meta/line sample paths** |
| Do Gray async_fifos / 2FF levels break functionally at 4:15? | **No (ratio-independent by construction)** — still verify throughput |
| Preferred PLL if native 720p24 proceeds | **30.000 MHz (3:1)**, not 24 — trade Fmax margin for CDC |
| Ship-proof | still **NO** until fit STA |

---

## 1. Related-edge arithmetic (INFERRED math; 20/90 Δ MEASURED)

Clocks phase-aligned at PLL (phase_shift 0). Setup launch clk_sys → capture clk_ddr:  
minimum positive rising-edge Δ over the edge family.

| clk_sys | ratio vs 90 | Unique setup Δ (ns) | Min Δ | vs data-delay class **3.5–4.9 ns** (MEASURED*) |
|--------:|-------------|---------------------|------:|-----------------------------------------------|
| **20** ship | 2:9 | 5.556, 11.111 | **5.556** | Headroom — STA PASS class (`8fdf440f` slack +0.793) |
| **24** preferred-old | **4:15** | **0†, 2.778, 5.556, 8.333, 11.111** | **2.778** (non-coincident) | **2.778 < 3.5 → expect SETUP HARD_FAIL** on timed meta |
| **25** | 5:18 | 2.222… | **2.222** | Already flagged FAIL in inventory |
| **30** | **1:3** | **11.111** only | **11.111** | Setup comfortable; **hold / same-edge family** (inventory) |
| **36** | 2:5 | 5.556, 11.111 | **5.556** | CDC like ship; **Fmax 36>32.59 paper NO-GO** |
| **45** | 1:2 | 11.111 | **11.111** | Fmax paper NO-GO |

\*MEASURED data-delay class from product `Plex.sdc` comments / inventory:  
`ac90b155` 4.111 · `ff2e3ca3` 4.892 · `8fdf440f` **3.832** ns (`c_line→c_line_v1`).  
\*20/90 min Δ **5.556 ns** MEASURED match on `8fdf440f` path panels.

†Coincidence (Δ=0): same rising edge every common period (166.67 ns). Quartus hold
checks dominate there; setup typically rolls to **next** ddr edge (**11.111 ns**).  
The **binding new hazard is 2.778 ns**, not the coincidence alone.

**This is the same defect class as Target A 25 MHz** in `docs/cdc-crossing-inventory.md`  
§“Related-edge sensitivity”.

---

## 2. Crossing enumeration (clk_sys ↔ clk_ddr)

Source of table: `docs/cdc-crossing-inventory.md` (MEASURED inventory on product path).  
Classification: **RI** = ratio-independent functional CDC · **RD-STA** = related-edge STA sensitive · **RD-TP** = throughput/margin sensitive to sys rate.

### ddr_frame_store (clk = clk_sys)

| # | Signal | Dir | Mechanism (quoted inventory) | Class | At 24/90 |
|---|--------|-----|------------------------------|-------|----------|
| 1 | reset | s→d | 2-FF async reset sync | RI | OK |
| 2 | swap_req toggle | s→d | 2-FF + toggle | RI | OK if ≥1 sys clk hold |
| 3–4 | pending_bank/ready | s→d | 2-FF level | RI | OK |
| 5–9 | disp_bank/buf, has_frame, swap_pending, pending_bank | d→s | 2-FF level | RI | OK (latency in cycles same) |
| 10–12 | vsync/start toggle, bank_sel | s→d | 2-FF toggle / level | RI | OK |
| 13 | want_y | s→d | **Gray** 2-FF | RI | OK; updates **20% more often** (RD-TP mild) |
| 14–15 | status_osd / sdram_status | s→d | Toggle-snapshot | RI | OK if data stable across toggle |
| 16/28 | input_fifo | s→d | **async_fifo Gray AW=2** (depth 4) | RI ptr; **RD-TP** | Producer **+20%**; ddr still 90 — deepen only if fill proof fails |
| 17 | line_buf_ram ×N | d wr / s rd | Dual-port M10K | RI addr; **RD-TP** | Sys reads faster → prep must keep up |
| **meta** | y_line/c_line/bank → \*_v1/\*_v2 | d→s | **Direct related-clock sample (STA-timed)** | **RD-STA** | **BLOCKER:** need ≥~5 ns edge; **2.778 ns insufficient** vs ~3.8 ns data |

### ddr_bus_arbiter (clk_m1 = clk_sys)

| # | Signal | Dir | Mechanism | Class | At 24/90 |
|---|--------|-----|-----------|-------|----------|
| 18 | reset | s→d | 2-FF | RI | OK |
| 19 | m1_want | s→d | 2-FF | RI | OK |
| 20 | m1 cmd bus | s→d | Protocol hold while !busy | RI; pulse width in ns shrinks | OK if held full sys cycle |
| 21 | m1_busy | d→s | reg + 2-FF | RI | OK |
| 22–23/30 | m1_rsp_fifo | d→s | **async_fifo Gray AW=3** (depth 8) | RI; **RD-TP** | **Consumer +20%** → drain **easier** (less risk) |

### present_npx_path (only if PRESENT_MULTI_PIXEL — L4 off on main)

| | | | | |
|--|--|--|--|--|
| pix fifo | sys↔pix | async_fifo AF_HEADROOM=4, AW=6 | RI; RD-TP | Macro off for native 1ppc plan — N/A unless MULTI on |

### async_fifo SDC cut (MEASURED policy)

```
set_false_path -from {*async_fifo*mem*} -to {*async_fifo*rd_data_r*}
```
Pointer Gray path remains timed. **Not** a whole-domain false_path.  
Valid at any ratio **if** Gray protocol intact (RI).

---

## 3. Faster producer / slower consumer (20→24)

| Path | Effect of +20% clk_sys | Risk |
|------|------------------------|------|
| sys→ddr **input_fifo** writes | More wr attempts/s | Low–med: ddr side still faster clock; AW=2 shallow — **watch occupancy under 720p doorbell** |
| ddr→sys **m1_rsp_fifo** reads | Sys pops faster | **Helps** |
| dual-port line RAM sys read | Higher scan demand | Med: underrun if prep bandwidth tight at 1280 |
| want_y Gray updates | More frequent | Low if Gray correct |
| **meta sample ddr→sys** | Unchanged data delay, **tighter STA edge** | **HARD FAIL class** |

AF_HEADROOM on npx (in flux on other branches): irrelevant if MULTI off; if enabled, +20% sys without AF retune is **RD-TP**.

---

## 4. MEASURED vs INFERRED

| Item | Kind |
|------|------|
| Crossing list #1–30 + mechanisms | **MEASURED** (inventory + RTL instance params AW=2/3) |
| 20/90 Δ = 5.556 ns STA | **MEASURED** (inventory / SDC / 8fdf440f) |
| data delay ~3.5–4.9 ns | **MEASURED** (quoted fits in SDC/inventory) |
| 24/90 unique Δ including **2.778 ns** | **INFERRED** (edge arithmetic, phase 0) — **must confirm in new STA Clocks/relationships panel** |
| “STA will HARD_FAIL meta at 2.778” | **INFERRED** from measured data delay vs inferred edge — **high confidence**, same method that correctly killed 25 MHz |
| async_fifo functional OK at 4:15 | **INFERRED** from Gray construction (no new sim at 24) |
| Fmax 32.59 nostub | **MEASURED** prior netlist only |

---

## 5. BLOCKER statement (loud)

### BLOCKER-CDC-24-90 (related-edge STA)

**Native 720p24 with clk_sys=24.000 MHz and clk_ddr=90.000 MHz is NOT clear to fit**  
until either:

1. **STA proves** all related setup/hold ≥ 0 at Slow 1100mV 100C including  
   `y_line/c_line` → `*_v1` class (inventory meta), **or**
2. **Design fix** before fit: retime meta on clk_ddr (or true async FIFO) so  
   path is not bare related-edge with ~4 ns data into **2.778 ns** window, **or**
3. **Choose different clk_sys** with min setup Δ ≥ ~5.5 ns (see §6).

Do **not** “fix” with `set_false_path` on the meta bus (forbidden; gate weakening).

Gray/2FF functional CDC is **not** the blocker. **Related-edge timing of non-FIFO paths is.**

---

## 6. Friendlier-ratio alternatives (pixel clock still ≥ 23.175)

Need ≥ **23.175 MHz** for 1312×736@24 (min blank).

| PLL clk_sys | Pixel OK? | CDC min setup Δ vs 90 | Fmax paper vs 32.59 | Recommendation |
|------------:|-----------|----------------------:|--------------------:|----------------|
| 24 | yes | **2.778 (BAD)** | +26% | **Defer** until meta fix or STA miracle |
| **30** | yes (V=953 @H=1312 → ~23.994 Hz) | **11.111 (GOOD setup)** | +7.8% thin | **PREFERRED native fit** |
| 36 | yes | 5.556 (like ship) | **FAIL paper** | NO-GO |
| 20 | Route B only | 5.556 | n/a | Default glass path |

### Revised preferred mode (CDC-first)

```
clk_sys  = 30.000000 MHz   # pll_0002 out0; 3:1 with 90
clk_ddr  = 90.000000 MHz   # unchanged
DE       = 1280 × 720
H_TOTAL  = 1312
V_TOTAL  = 953             # 30e6/(1312*953) ≈ 23.9936 Hz ≈ 24/1
```

Hold STA mandatory at 3:1 (inventory). Fmax must still clear **30 MHz** on the **actual** L4 netlist (32.59 is prior only).

Optional: keep **24 MHz** only as a **second** experiment after meta retime lands.

---

## 7. What does NOT block

- 2-FF synchronizers (levels/toggles/reset)
- Gray want_y
- async_fifo pointer CDC (input_fifo, m1_rsp_fifo) — ratio-independent
- 1:1 film cadence / no Bresenham for 24/1 content
- ascal HDMI ~60 glass

---

## 8. Fit-kit impact

| Artifact | Update |
|----------|--------|
| PLL_EDIT | Add **30 MHz primary**; 24 MHz demoted pending meta fix |
| SDC | Primary `Plex_native720p24_cdc30.sdc` (30/90); keep 24 SDC as experimental |
| STA criteria | Fmax ≥ **30** for primary path; require related-edge slack ≥ 0; path owner named |
| RISKS | Promote CDC 4:15 / 2.778 ns to **blocker** |

