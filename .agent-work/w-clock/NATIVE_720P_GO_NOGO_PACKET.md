# Native 720p GO/NO-GO packet (one page)

**Lane:** w-clock · **No fit applied · analysis-only STA path dump only**  
**Date artifact:** nostub RBF `c74c6863` · device `5CSEBA6U23I7`  
**Corner (MEASURED):** TimeQuest **Slow 1100mV 100C Model** · Timing Models **Final**  
→ Not typical. Thin margin is **slow-corner** margin.

---

## 1. Who owns Fmax 32.59? (MEASURED — settled)

| | |
|--|--|
| **Artifact** | `fit-nostub-chrome` db + analysis-only `quartus_sta` dump |
| **Dump** | `.agent-work/w-clock/nostub-path-dump/clk_sys_emu_sameclk.txt` |
| **Fmax Summary** | `Plex.sta.rpt` L128: **32.59 MHz** on `emu\|pll\|…general[0]…divclk` (= clk_sys) |
| **Path #1** | **From** `stream_path:spath\|slice_hdr_parser:slp\|r_tc[1]` |
| | **To** `stream_path:spath\|slice_hdr_parser:slp\|residual_csum[5]` |
| **Slack / delay** | **19.318 ns** @ 50 ns rel · data **30.062 ns** |
| **Math** | `1000/(50−19.318) = 32.59 MHz` = Fmax exactly |

**Top 20 same-clock paths are the same cone** (`r_tc[*]` → `residual_csum[*]`).

### Classification

| Question | Answer |
|----------|--------|
| Placeholder / `decode_stub`? | **NO** — stub has **0** fit.rpt rows on this RBF |
| Present / beam / ascal? | **NO** |
| What is it? | **`slice_hdr_parser` residual XOR fold** (R-csum6 product sticky path, `(* keep *) residual_csum`) inside **stream_path** |
| Throwaway? | **NO** — real fabric residual / status ladder; kept under `PRODUCT_NO_STUB` |
| Eats the 7.8%? | **This keep-cone**, not the glass path |

**Present/scaler is not the Fmax owner.** Ceiling is stream residual logic on clk_sys.

---

## 2. Scope fence (do not conflate)

| Netlist class | clk_sys Fmax | Notes |
|---------------|-------------:|-------|
| Stub-in (deploy2) | **23.46** | owner = `decode_stub` MV — cargo |
| **Nostub ARM-present** (`c74c6863`) | **32.59** | owner = `slice_hdr_parser` residual_csum |
| Nostub + **full fabric H.264** | **UNKNOWN** | no STA; will move Fmax |
| Native 720p beam RTL @ raised clk | **UNKNOWN** | must re-fit |

**Honest claim only:**  
> Native 720p beam is **paper-feasible for a nostub core that does ARM decode + fabric present**, with stream residual still mapped.  
> **Not** proven for fabric-decode-in. **Not** proven until the raised-clk fit.

---

## 3. Pixel clock & blanking (arithmetic)

1ppc; DE = **1280×720**. HDMI/ascal may still be CEA on `pll_hdmi` — core beam need not be CEA.

| Beam totals | clk @24 | clk @30 | vs Fmax 32.59 |
|-------------|--------:|--------:|---------------|
| Min-pad **1312×736** | 23.18 | **28.97** | OK @30 |
| “Tight” **1344×750** | 24.19 | **30.24** | OK paper; integer PLL 30 **short** |
| **CEA 1650×750** | 29.70 | **37.12** | **DEAD @30** |

**Say plainly:** shipping native 720p means **tight/min blanking, not CEA-861 line timing.**

### Recommended fit target (integer PLL, VCO360-class)

| Item | Value |
|------|------:|
| **clk_sys** | **30.000000 MHz** (`output_clock_frequency0`) |
| clk_ddr | **90.000000 MHz** unchanged |
| PLL | integer family; VCO **360** MEASURED (`×36/÷5` from 50 ref in STA derive) |
| **Why not 36** | 36 > 32.59 → **paper FAIL** before beam RTL |
| **Why not 30.24 frac** | optional later; 30.0 integer is cleaner first fit |
| **H_TOTAL** | **1312** (1280+32 min pad) |
| **V_TOTAL @30 class** | **762** → 30.0077 Hz @30 MHz; or Bresenham **762/763** → ~29.97 |
| **V_TOTAL @24 class** | ~**953** / Bresenham for 23.976 |
| DE | **1280×720** true content DE |

At **30 MHz + 1344×750**: fps only **29.76** — misses 30 and 29.97. Prefer **H=1312**.

---

## 4. STA gates the fit must pass (copy into grant)

```text
NETLIST: PRODUCT_NO_STUB=1 (or equiv); decode_stub hierarchy rows = 0
PLL:     out0 = 30.000000 MHz; out2 = 90.000000 MHz; no HPS/ddr hard-IP retune
BEAM:    DE 1280×720; H_TOTAL=1312; V from class/Bresenham (~762/953)
CORNER:  Slow 1100mV 100C (and report Fast if available — do not sign off on Fast alone)

G1  Fmax(clk_sys general[0]) ≥ 30.00 MHz          (quote Fmax Summary)
G2  setup slack clk_sys @ 30 MHz period ≥ 0        (constrained, not just Fmax panel)
G3  Path #1 From/To NAMED; must not be decode_stub
G4  clk_sys↔clk_ddr related setup slack ≥ 0        (no false-path to hide)
G5  post-fit hierarchy: present_beam + DE 1280 live; ascal still clocks on pll_hdmi
G6  NEW_RBF ∉ banned set; ONE menu deploy after BUILD_OK
G7  HDMI capture (parent): active 1280-class content, not black; cadence not 20.7 Hz

PRE-REG score after fit:
  HIT  = G1–G7 all true with quotes
  MISS = any fail → native 720p stays NO-GO; keep Route B
```

**CDC note:** 30/90 = exact **3:1** related family (cleaner than 25/90). Still requires G4 — not free.

---

## 5. GO / NO-GO

| Claim | Verdict |
|-------|---------|
| Kill-by-23.46 forever | **WITHDRAWN** (stub path) |
| CEA 720p30 core beam | **NO-GO** (37.12 > 32.59) |
| Integer **36 MHz** sys | **NO-GO** on current nostub Fmax |
| **30 MHz + 1312×V native DE 1280×720**, nostub ARM-present | **CONDITIONAL GO** — paper clears; **ship only after G1–G7** |
| Same after fabric H.264 in | **NO-GO until new STA** (unmeasured) |
| Route B @20 MHz glass 720p | **Still default** until G1–G7 HIT |

**Parent action when fit slot opens:** run the 30 MHz / H=1312 native-DE experiment against G1–G7; capture glass. Do not advertise “CEA 720p.” Do not add fabric decoder in the same fit.
