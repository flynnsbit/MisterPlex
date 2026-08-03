# PLL configuration change — native 720p24 (DO NOT APPLY until parent sequences)

## PRIMARY (CDC-safe): clk_sys = 30.000 MHz

**Why not 24:** CDC audit — 24/90 min related setup Δ **2.778 ns** < measured meta
data-delay class ~3.8 ns → related-edge STA BLOCKER. See `CDC_RATIO_24_90_AUDIT.md`.

### Instance
| Field | Value |
|-------|--------|
| File SoT | `fpga/Plex_MiSTer/rtl/pll/pll_0002.v` |
| Product | `PRESENT_CLK_PIX_PLL` **off** → clocks=3, fractional=false |

### Concrete edit (PRIMARY)

```systemverilog
// before
.output_clock_frequency0("20.000000 MHz"),
// after PRIMARY
.output_clock_frequency0("30.000000 MHz"),
```

Unchanged:
```systemverilog
.output_clock_frequency1(`MISTERPLEX_SDRAM_PLL_FREQ),
.output_clock_frequency2("90.000000 MHz"),
```

**Ratio:** 30:90 = **1:3** exact. Setup min Δ = **11.111 ns**. Hold same-edge family — STA hold must pass.

**Beam for ~24 Hz content @ 30 MHz:** H=1312, V=953 → fps ≈ 23.9936 Hz.

**VCO class (INFERRED):** 360/12 = 30 for C0 (was 360/18 = 20).

---

## EXPERIMENTAL only (blocked until meta retime or STA miracle): 24.000 MHz

```systemverilog
.output_clock_frequency0("24.000000 MHz"),
```

H=1312 V=762 → 24.006 Hz. **CDC 4:15 — do not release slot on this alone.**

---

## Must NOT
- Raise HPS/DDR3 hard-IP clocks  
- Edit stale `pll.v` megawizard as SoT  
- Ship without STA_PASS + hierarchy 1280 DE  
