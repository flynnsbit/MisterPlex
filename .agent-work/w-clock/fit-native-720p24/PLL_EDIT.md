# PLL configuration change — native 720p24 (DO NOT APPLY until parent sequences)

## Instance
| Field | Value |
|-------|--------|
| File SoT | `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` |
| Megafunction | `altera_pll` instance `altera_pll_i` inside `pll_0002` |
| Wrapper | `fpga/Plex_MiSTer/rtl/pll.v` (megawizard strings **STALE** — do not edit as SoT) |
| Refclk | `50.0 MHz` (`reference_clock_frequency`) |
| Product path | `PRESENT_CLK_PIX_PLL` **undefined** → `number_of_clocks(3)`, `fractional_vco_multiplier("false")` |

## Concrete edit (one line)

**Before (shipping):**
```systemverilog
		.output_clock_frequency0("20.000000 MHz"),
```

**After (native 720p24 fit grant):**
```systemverilog
		.output_clock_frequency0("24.000000 MHz"),
```

Leave unchanged:
```systemverilog
		.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),  // typically 100 MHz class
		.output_clock_frequency2("90.000000 MHz"),
		.output_clock_frequency3("0 MHz"),  // when PRESENT_CLK_PIX_PLL off
```

## Counter / VCO intent (INFERRED family — STA must confirm)

Prior analysis class (not a new fit measurement):
- VCO ≈ **360 MHz** with ref 50: \(M/N = 36/5\) class  
- out0 @ 20 MHz ↔ C0 = 18 (360/18)  
- out2 @ 90 MHz ↔ C2 = 4 (360/4)  
- out0 @ **24 MHz** ↔ C0 = **15** (360/15)  

Quartus re-picks C counters from the frequency string; we do **not** hand-edit raw M/N/C in this IP.

## Effect on EXISTING outputs

| Output | Role | Change |
|--------|------|--------|
| **outclk_0** | `clk_sys` (Plex.sv `.outclk_0(clk_sys)`) | **20 → 24 MHz** — **entire fabric sys domain** |
| outclk_1 | SDRAM PLL | **unchanged** string |
| outclk_2 | `clk_ddr` | **unchanged 90 MHz** |
| outclk_3 | clk_pix (macro off) | still 0 / unused |

**Ratio clk_sys:clk_ddr:** 20:90 (2:9) → **24:90 (4:15)**.  
Not 3:1. CDC related-edge family changes — STA must re-prove (G4).

## Optional alternate (cleaner CDC, less Fmax margin)

If parent prefers integer 3:1 related clocks:
- out0 = **30.000000 MHz**, H=1312, V=953 → fps ≈ 23.994 Hz  
- Still DE 1280×720; more Fmax pressure (need ≥30 vs measured 32.59 paper)

Preferred packet mode remains **24 MHz + 1312×762**.

## Must NOT
- Raise HPS / DDR3 hard-IP clocks  
- Enable `PRESENT_CLK_PIX_PLL` in the same fit unless sequenced  
- Edit only `pll.v` megawizard banner strings  
- Ship this edit without BUILD_OK + STA_PASS_CRITERIA  

## QSF companions (L4 — parent/w-osd sequence, not this lane alone)

```tcl
# Illustrative — exact merge is parent/w-osd
set_global_assignment -name VERILOG_MACRO "FRAME_W=1280"
set_global_assignment -name VERILOG_MACRO "FRAME_H=720"
# Beam path: either BEAM_960 off with native DE runtime, or dedicated native macro
# PRESENT_BEAM_960 is 960 max tier — native 1280 conflicts with first-fit BEAM_960 rules.
# Parent must choose: Route B 960@20 vs native 1280@24 — not both macros on.
```

Native 1280@24 is **not** `PRESENT_BEAM_960` (that caps 960 and forbids MULTI).  
Fit netlist must actually **instantiate** the 1280 DE beam (L3) and **enable** it (L4).
