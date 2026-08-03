# Runtime-variable raster + B2b + overclock honesty (w-clock)

**Date:** 2026-08-03  
**Lane:** w-clock (`p720-clock`)  
**Fit:** NOT run (held by parent). No invented BUILD_OK.

Parent measured PMS does **not** upscale — delivered DE is source-dictated (e.g. 320×240
when 960×540 was requested). DE must track delivery; ascal lifts true DE to glass.

---

## 1. Does runtime-variable H/V close timing?

### What exists today
| Signal | Before this commit | After |
|--------|-------------------|--------|
| V_TOTAL | runtime via `rt_vtotal`, latched at `v_wrap` | unchanged |
| H_DE / H_TOTAL / V_ACTIVE | parameters (constant-folded compares) | optional `use_rt_geom` + frame-boundary latch (**default OFF** in `present_core`) |
| Sync | fixed params | fixed when geom OFF; derived from latched actives + porches when ON |

### Structural path class
Blanking is still:

```
HBlank <= (hc_n >= hde_act);   // 11-bit magnitude compare
h_wrap  = (hc == htot_act-1);
```

That is the **same class** as the already-shipping `vtot_act` path (register vs counter),
not a multi-cycle decode cone. Constant-folded `11'(H_DE)` can be slightly cheaper; the
delta is typically **0–1 LUT level** on the blanking cone.

### Measured Fmax context (prior fits — not this netlist)
| Netlist | Fmax clk_sys | Source |
|---------|--------------|--------|
| stub-in `8fdf440f` | **23.46 MHz** | STA Fmax Summary (prior) |
| nostub `c74c6863` | **32.59 MHz** | STA Fmax Summary (prior) |
| ship constraint | **20.0 MHz** | PLL `pll_0002.v` outclk_0 |

Stub margin over 20 MHz: `23.46/20 − 1 = 17.3%` (awk). Thin if runtime geom ever
shares the critical path. Nostub margin: `32.59/20 − 1 = 63%`.

### Verdict (honest)
| Config | STA close at 20 MHz? |
|--------|----------------------|
| Fixed 960×540, V=564 | **Expect meet** (medium) — unknown slack until `Plex.sta.rpt` |
| Fixed H, V_TOTAL=705 via `rt_vtotal` | **Expect meet** (medium) — data change only on existing latch |
| `use_rt_geom=1` (full H/V runtime) | **UNKNOWN until fit** — structure low-risk; stub 17% margin is the worry |
| Claim "closes" without sta.rpt | **FORBIDDEN** (rule 0) |

**Pre-registered prediction (runtime geom ON, nostub-class BEAM_960):** meet 20 MHz  
**Miss:** Fmax_sys < 20 or any setup slack < 0 → HARD FAIL, publish miss.

Host must still latch geom only at frame boundary (implemented). Mid-frame H_TOTAL
change with `hc` past new last is a stall class — same bug rd-duck caught on V.

---

## 2. B2b — `present_video_timing_960.sv` status

**Decision: DEMOTE to math/constant pack only.**

| Role | Module |
|------|--------|
| **Raster SoT** (hc/vc/DE/HS/VS) | `present_beam_content_de.sv` only |
| **FPS/geometry arithmetic oracle** | `present_video_timing_960.sv` |
| Instantiated in `present_core`? | **No** (removed dual SoT) |

Rationale: two modules claiming timing ownership is how silent mismatch ships. Gate
expectations must require beam hierarchy, not a phantom generator inside timing_960.

---

## 3. STA ack V_TOTAL=705 (24 Hz companion)

```
H_TOTAL = 1182 (fixed)
V_TOTAL = 705  (rt_vtotal)
fps     = 20e6 / (1182*705) = 24.0007… Hz
fps_milli ≈ 24000
active  = 960*540*24.0007 ≈ 12.442 Mpix/s  (< 20 MHz 1px ceiling)
```

Same RBF serves 564 and 705 via `rt_vtotal` latch. Oracle TB proves no frame-start stall
at 705. **STA:** expect meet 20 MHz; slack unknown until report.

---

## 4. Overclock headroom (PLL still unapplied)

| Item | Value | Evidence |
|------|-------|----------|
| PLL SoT | `pll_0002.v` 20 / 90 MHz | file strings |
| Target A 25 MHz stub-in | **blocked** | 25 > 23.46 Fmax |
| Target A 25 nostub | possible intra-sys; **CDC risk** 25/90 related edge ~2.22 ns | analysis, needs STA |
| Target B 30 nostub | ~2.6 MHz margin vs 32.59 — placement risk | arithmetic |
| PIX PLL 29.7 / 37.125 | upgrade path, macros OFF | plan docs |
| Realistic ceiling | **unknown beyond measured Fmax** without new BEAM_960 fit | rule 0 |

First ascal-native fit stays **20 MHz**. Aggression = proven headroom after STA, not blind bumps.

---

## 5. Applied vs proposed

| Change | State |
|--------|-------|
| B2b demote timing_960; beam sole SoT | **Applied** on branch |
| Runtime geom ports + frame latch | **Applied** RTL; **OFF** in present_core |
| Identity DE uses latched hde/vact | **Applied** |
| PLL bump | **Not applied** |
| Quartus fit | **Not run** |

Parent verify:
```
tests/unit/test_present_beam_960_oracle.sh
tests/unit/test_present_beam_960_elab.sh
tests/unit/test_present_beam_960_arith.sh
```

## Appendix (awk)
```
stub_margin_pct=17.30
nostub_margin_pct=62.95
25_vs_stub=1.54
30_vs_nostub_margin_mhz=2.59
fps705=24.000672
mpix705=12.442
```

## Exact oracle (parent defect fix)

Prior RTGEOM used `de_pix < W*H*2` lower-bound; measured 154559 vs 153600 allowed mid-line stop and would not catch one-drop-per-line.

**Now:** whole-frame equality + `line_acc=W..W` for 320×240, 640×360, 960×540; red twin `FAULT_DROP_ONE_PER_LINE`.
See `STA_V705_AND_OVERCLOCK_CEILING.md`.
