# PRESENT_CLK_PIX_PLL enable recipe (w-clock)

**Status:** default **OFF** on product. Parent-granted exclusive fit only.  
**Canvas:** product `FRAME_W=1280` `FRAME_H=720` already live on main.  
**No fit by this doc.** Pre-register STA before packaging digests (Sweep 136 compose class).

---

## 1. Exact arithmetic (SoT)

CEA-861 pack used by `present_beam_ppc` / `present_video_timing_720p.sv`:

| Symbol | Value |
|--------|------:|
| H_DE / V_ACTIVE | 1280 / 720 |
| H_TOTAL / V_TOTAL | **1650 / 750** |
| PIX_PER_FRAME | 1650 × 750 = **1_237_500** |
| f_pix @ 24 fps (pack, non-VIC) | 1_237_500 × 24 = **29_700_000 Hz** |
| f_pix @ 60 fps (VIC 4) | 1_237_500 × 60 = **74_250_000 Hz** |
| True CEA VIC 60 720p24 | H=3300 → **59.40 MHz** (not this PLL default) |

PLL SoT: `fpga/Plex_MiSTer/rtl/pll/pll_0002.v`  
- default out3 string: `"29.700000 MHz"`  
- `PRESENT_CLK_PIX_74_25`: `"74.250000 MHz"`

### Anti-16 Hz trap (do not re-open)

With CEA totals and `clk_pix == clk_sys == 20 MHz`:

```
fps_eff = 20_000_000 / 1_237_500 ≈ 16.16 Hz
```

Enabling `PRESENT_MULTI_PIXEL` **without** `PRESENT_CLK_PIX_PLL` (or a compact L4 beam) drops glass into the **~16 Hz trap**. Never “fix” 720p glass by slowing refresh into that band.

---

## 2. QSF + SDC enable recipe (exact)

Product already has (leave as-is):

```tcl
set_global_assignment -name VERILOG_MACRO "PRODUCT_NO_STUB=1"
set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"
set_global_assignment -name VERILOG_MACRO "FRAME_H=720"
```

**Uncomment / add for CEA 720p24 clk_pix compose** (all required together):

```tcl
set_global_assignment -name VERILOG_MACRO "PRESENT_MULTI_PIXEL=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_PX_PER_CLK=1"
set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_PLL=1"
set_global_assignment -name SDC_FILE Plex_clk_pix.sdc
```

| Line | Role |
|------|------|
| `PRESENT_MULTI_PIXEL` | CEA beam + `present_npx_path` (async FIFO group path) |
| `PRESENT_PX_PER_CLK=1` | Land forces PPC=1 until `ddr_frame_store` N-wide RGB (`$error` if PPC≠1) |
| `PRESENT_CLK_PIX_PLL` | `pll_0002` `number_of_clocks(4)`, out3 = 29.700000 MHz |
| `SDC_FILE Plex_clk_pix.sdc` | async clock groups clk_pix ⊥ clk_sys and clk_pix ⊥ clk_ddr |

**Optional (later, not first glass):**

```tcl
set_global_assignment -name VERILOG_MACRO "PRESENT_CLK_PIX_74_25=1"  ;# 74.25 MHz — no in-repo Fmax proof
# PRESENT_PX_PER_CLK=2 only after N-wide store (unique pixels, not {PPC{fr}} replicate)
```

**Mutually exclusive with L4 compact path** (`PLEX_PRESENT_720P_L4` / 1312×762). Do not stack L4 + MULTI.

**Source files (already on tip, flag-gated):**

| File | What |
|------|------|
| `rtl/pll/pll_0002.v` | frequency SoT + 4-clock branch |
| `rtl/pll.v` | wrapper outclk_3 |
| `Plex.sv` | `.clk_pix(clk_pix_pll)`; `CLK_VIDEO=clk_pix_pll` when MULTI+PLL |
| `Plex_clk_pix.sdc` | named general[3] + `set_clock_groups -asynchronous` |
| `rtl/present_npx_path.sv` | gray async_fifo + 2FF prefill_go |

---

## 3. Throughput honesty (not STA)

| clk_sys | PPC | fabric Mpix/s into FIFO | vs 29.70 | vs 74.25 |
|--------:|----:|------------------------:|----------|----------|
| 20 | 1 | 20.0 | **FAIL** long-term feed | FAIL |
| 20 | 2 | 40.0 | PASS rate (if unique lanes) | FAIL |
| 20 | 4 | 80.0 | PASS | PASS |

- Glass pixel rate with PLL@29.70 = **29.70 Mpix/s** (1 sample / CE_PIXEL / clk_pix).  
- Fabric production ≈ `F_sys × PPC`. PPC=1@20 cannot sustain blanking clocks at 29.70 forever → underrun / freeze risk, **not** an STA green-wash.  
- Today MULTI replicates scalar store: `mp_npx_r = {PRESENT_PPC{fr}}` — PPC>1 is **rate-true, content-false** until store is N-wide.

---

## 4. PRE-REGISTER STA (Sweep 136 compose class) — P1–P5

**Corner:** Slow 1100mV 100C Final (product class).  
**Netlist assumption:** product nostub + FRAME 1280×720 + MULTI + clk_pix@29.70 + `Plex_clk_pix.sdc`.  
**Settled parent note:** Sweep 136 compose is **STA coin-flip** — pre-register bands, not digests.

| ID | Claim | Predicted | Owner / path | PASS criterion | Risk |
|----|-------|-----------|--------------|----------------|------|
| **P1** | clk_sys @ 20 MHz setup | setup ≥ 0; restricted Fmax **≥20**, likely **22–36** depending on residual_csum land | sameclk residual / present (not decode_stub) | setup≥0 all clk_sys paths; Fmax≥20 | MED — nostub historically ~32; stub-class ~23 |
| **P2** | clk_ddr @ 90 MHz | setup ≥ 0; Fmax **≥90** (prior ~90–96) | DDR bridge / fstore | setup≥0; Fmax≥90 | LOW–MED |
| **P3** | clk_pix general[3] @ 29.70 | Fmax **≥29.7**, predicted **≥40** if unpack light | `present_npx_path` unpack / CE path | Fmax(general[3])≥29.70; setup≥0 inside pix domain | MED — first real domain |
| **P4** | CDC false-related-edge | **no** related-edge fails on FIFO gray if SDC sourced | async groups in `Plex_clk_pix.sdc` | zero unexplained sys↔pix setup fails on gray/2FF | LOW if SDC on; **HIGH if SDC omitted** |
| **P5** | Compose congestion coin-flip | overall fit/STA **PASS or FAIL either way** without recipe bug | route / ALM pressure MULTI+FIFO+720p | parent scores fit.rpt; neither PASS nor FAIL is “proof of clock math” alone | **HIGH — settled Sweep 136 coin-flip** |

### Explicit non-claims

- **P3 PASS ≠ 24 fps unique content.** Rate wall at PPC=1@20 remains.  
- **74.25 MHz:** predicted **FAIL or high risk** — no MEASURED present-path Fmax≥74.25 in-repo.  
- **decode_stub as Fmax owner:** must be **NO** (parent miss #18 class).  
- **clk_sys retune to 24 MHz:** rejected for CEA 29.70 path; compact L4 only.

### Miss codes (post-fit interrogation)

| Code | Miss if |
|------|---------|
| M1 | clk_sys setup &lt; 0 or Fmax &lt; 20 |
| M2 | Fmax owner = decode_stub / placeholder |
| M3 | PLL flag ON but general[3] missing / 0 MHz |
| M4 | clk_pix Fmax &lt; 29.70 (or &lt; 74.25 if 74_25 flag) |
| M5 | residual combo owns with &lt;5 ns slack @20 |
| M6 | `Plex_clk_pix.sdc` omitted → false related-edge fails on FIFO gray |
| M7 | `CLK_VIDEO` left on clk_sys while MULTI+PLL emits on clk_pix (domain split) |

### Post-fit commands (parent / w-fit)

```bash
# After exclusive fit:
python3 scripts/check_quartus_timing.py --sta-rpt OUT/Plex.sta.rpt --min-fmax-mhz 20
# Interrogate ALSO: general[3] Fmax ≥ 29.70; present_npx_path setup on clk_pix
# Prefer: scripts/sta_onepass_interrogation.sh if present in tree
```

Prior MEASURED (different netlists — do not transfer as compose proof):

| Netlist class | clk_sys Fmax | note |
|---------------|-------------:|------|
| stub-class retained | ~23.17 | PASS@20 FAIL@24 |
| nostub historical | ~32.59 | residual_csum owner |
| clk_pix | **absent** (macro OFF) | n/a |

---

## 5. CDC / SDC inventory (new domain)

### Crossings when `PRESENT_CLK_PIX_PLL=1` + MULTI

| # | Crossing | Dir | Width | Protection | Verdict |
|---|----------|-----|------:|------------|---------|
| P1 | `present_npx_path` group bus | clk_sys→clk_pix | group | `async_fifo` gray pointers | SAFE |
| P2 | `prefill_go` | clk_sys→clk_pix | 1 | 2FF (`prefill_go_p1/pix`) | SAFE |
| P3 | `reset` into pix | async assert | 1 | 2FF `mp_rst_pix0/1` | SAFE |
| P4 | CE_PIXEL / RGB / H/V out | clk_pix | — | same domain; `CLK_VIDEO=clk_pix_pll` | SAFE (after Plex.sv fix) |
| P5 | ddr_frame_store rd / beam | clk_sys↔clk_ddr | — | existing inventory B1–B3; **unchanged** | existing |

`Plex.sdc` already false_paths `async_fifo` mem→rd_data_r (all instances, including npx FIFO).  
`Plex_clk_pix.sdc` adds async groups: **clk_pix ⊥ clk_sys**, **clk_pix ⊥ clk_ddr**.  
**Do not** put clk_sys↔clk_ddr in exclusive groups here (product related-edge intentional).  
**Do not** false_path residual_csum.

### Missing / watch items

| Item | Status |
|------|--------|
| Source `Plex_clk_pix.sdc` when PLL ON | Required — M6 if omitted |
| `derive_pll_clocks` creates general[3] | OK when `number_of_clocks(4)` |
| `expected_sta_clocks` fixture lists only [0],[2] | Intentional for product OFF; compose gate must also require [3] |
| intentional multicycle sys↔pix | None — groups only |
| CLK_VIDEO domain | Fixed: MULTI+PLL → `clk_pix_pll` |
| beam still on clk_sys | By design; only FIFO crosses to pix |
| unique feed @ PPC=1 | Functional wall, not missing SDC |

---

## 6. RTL contract checklist

- [x] PLL out3 behind `PRESENT_CLK_PIX_PLL` (default OFF)  
- [x] `Plex.sv` `.clk_pix(clk_pix_pll)` under flag  
- [x] `CLK_VIDEO` tracks `clk_pix_pll` when MULTI+PLL  
- [x] QSF recipe commented; product FRAME 1280×720 live  
- [x] SDC async groups + exclusion baseline fingerprints  
- [ ] Exclusive compose fit + STA score (parent / w-fit)  
- [ ] Device glass @ ~24 Hz (parent only)  

---

## 7. Related docs

- `docs/cdc-crossing-inventory.md` — PRESENT_CLK_PIX_PLL section  
- `docs/PRODUCT_720P_GEOMETRY.md` — 1280×720 identity canvas  
- `Memory/lab/w-clock-CLOCK_PLAN_720P.md` — arm A vs B decision  
- `tests/unit/test_720p_clk_ddr_arith.py` — arithmetic + default-OFF gates  
