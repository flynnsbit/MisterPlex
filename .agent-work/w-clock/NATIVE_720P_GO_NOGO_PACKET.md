# Native 720p GO/NO-GO packet (revised — asset is **24 fps**)

**Lane:** w-clock · **No fit applied** · analysis-only STA only  
**Asset (parent MEASURED, ffprobe bytes):** rk=7 1280×720 **r_frame_rate 24/1**, Constrained Baseline, no B  
**Prior project sizing at 30 fps is SUPERSEDED for this asset.**  
**Fmax artifact:** nostub `c74c6863` · **32.59 MHz** · corner **Slow 1100mV 100C Final**

---

## 0. Parent’s ~24.19 MHz — verdict

Parent computed `30.24 × (24/30) ≈ 24.19` and flagged it INFERRED.

**When H_TOTAL and V_TOTAL are held fixed, rate scales linearly with fps.**  
`1344 × 750 × 24 = 24.1920 MHz` **equals** that scale — **arithmetic HIT** for the *tight* geometry.

**Where linear scale is wrong:** a *standard mode* may change H_TOTAL.  
True **CEA-861 VIC 32** 720p24 is **3300×750 @ 59.40 MHz**, not 1650×750 @ 29.7.  
Do not treat 24.19 as “the CEA number.”

---

## 1. Fmax owner (MEASURED — unchanged)

| | |
|--|--|
| Fmax | **32.59 MHz** clk_sys (`Plex.sta.rpt` / dump) |
| Path | `slice_hdr_parser` `r_tc[*]` → `residual_csum[*]` |
| Slack | 19.318 ns @ 50 ns · data 30.062 ns |
| Corner | **Slow 1100mV 100C Final** (not typical) |
| Stub? | **NO** on nostub netlist |
| Present/beam? | **NO** |

Dump: `.agent-work/w-clock/nostub-path-dump/clk_sys_emu_sameclk.txt`  
**7.8% was the @30 tight margin story; @24 margins are larger (below). Owner is still residual_csum keep-cone — not luck-without-name.**

---

## 2. Pixel clock for native **1280×720 @ 24 Hz** (1ppc)

DE fixed **1280×720**. Pads from `present_beam_content_de.sv`:  
`htot_min_pad=32` → H≥**1312**; `vtot_min_pad=16` → V≥**736** (MEASURED source lines 83–96).

| Class | H_TOTAL | V_TOTAL | Assumption | clk @ 24.000 | vs Fmax 32.59 |
|-------|--------:|--------:|------------|-------------:|---------------|
| **(a) min blank** | **1312** | **736** | product min pads only | **23.175 MHz** | **+28.9% CLEAR paper** |
| **(b) tight** | **1344** | **750** | same totals as prior “tight@30” | **24.192 MHz** | **+25.8% CLEAR paper** |
| **(c) 60-line @24** | **1650** | **750** | 720p60 line structure, 24 Hz refresh | **29.700 MHz** | **+8.9% CLEAR paper** |
| **(c′) CEA VIC 32** | **3300** | **750** | real CEA-861 720p24 | **59.40 MHz** | **DEAD** (≪ Fmax) |

**INFERRED vs MEASURED**
- Totals (a)(b): **INFERRED** design choices; pad floors **MEASURED** from RTL.
- Clocks: **ARITHMETIC** from totals×24 (not STA).
- Fmax 32.59: **MEASURED** STA.
- VIC 32 59.40: **standard fact** (CEA); not a lab measurement.

**`present_video_timing_720p.sv` note:** comments use 1650×750 @ 29.70 for “CEA 720p24” — that is **(c) reduced-clock 60-line**, **not** VIC 32. Correct the name when landing.

**Parent 24.19:** correct for **(b)** only. Prefer citing **23.175 (a)** / **24.192 (b)** / **29.700 (c)** with H/V explicit.

---

## 3. Integer PLL (VCO360 class) vs 720p24

Envelope (prior): integer spare on VCO360: **24 / 30 / 36 / 40 / 45** MHz (INFERRED family; 20/90 product MEASURED).

| PLL clk_sys | (a) 1312×736 | (b) 1344×750 | (c) 1650×750 | Notes |
|------------:|-------------:|-------------:|-------------:|-------|
| **24.000** | fps **24.854** (V=736 min) | fps **23.810** | fps **19.394** | No exact 24.000 with integer H×V≥min: **H×V must be 1 000 000** at 24 MHz; no factor pair with H≥1312 and V≥736 |
| **24.000** + V choose | V=**762** → **24.0061 Hz**; V=**763** → **23.9747 Hz** @ H=1312 | — | — | Closest 1:1 without fractional PLL |
| **30.000** | easy headroom | fps@750=29.76 | fps@750=**24.242** | (c)@30 ≈24.24 Hz; or H=1312 V=**953** → **23.994 Hz** |

**“Unusually clean 24 MHz” second look:**  
24 MHz integer is **reachable on VCO360**, but it does **not** give exact 24.000 Hz on min-legal 1280×720 totals without fractional V or Bresenham.  
Closest: **H=1312, V=762 → 24.0061 Hz** (41 ppm fast vs 24.000) — fine for exact-24 content; optional micro-dither 762/763 if you want long-run 24.000.

**Recommended first native-720p24 fit target (paper):**
- **clk_sys = 24.000 MHz** integer (or stay **30.000** if sharing a 30 MHz experiment)  
- **H_TOTAL = 1312**, **V_TOTAL = 762** (exact-ish 24.006) or **736** only if accepting 24.85 Hz  
- clk_ddr **90** unchanged  
- **Not** VIC 32 / 59.4  

At 24 MHz, Fmax margin **(32.59−24)/32.59 ≈ 26%** on the residual_csum owner (paper) — still must pass constrained STA @ 24 MHz period.

---

## 4. Cadence (CHANGED by 24/1 asset)

| Regime | Content | Core beam rate | Pulldown / Bresenham `{705,706}`? |
|--------|---------|----------------|-------------------------------------|
| **A — native 720p24 beam (this packet default)** | **24/1** exact | **≈24 Hz** 1:1 | **NO** — 1:1; film NTSC dither **not required** for this asset |
| **A′ — 23.976 tagged as 24** | if mislabeled | 24.000 beam | slip ~**41.7 s**/frame (same class as before) |
| **B — Route B content DE @20 MHz** | 24/1 | H=1182 path | separate; `{705,706}` was for **that** H @20 MHz NTSC lock |
| **C — panel/HDMI 60 Hz** | 24/1 | core 24 unique f/s into **ascal** | MiSTer **pll_hdmi + ascal** still drive ~**60 Hz glass**; 24→60 is ascal triple-buffer / display path, **not** core V_TOTAL dither. Judder is ascal/panel class, not Bresenham film |

**Confirm:** For **exact 24/1 content on exact ~24 Hz core beam**, **no** `{705,706}` duty 0.72476.  
That dither remains relevant for **NTSC 23.976/29.97** on the **20 MHz / H=1182** path, or if q5 says 1000/1001.

**If display will not accept 24 Hz HDMI:** product already targets **ascal → ~60 Hz HDMI** (Regime C). Packet does **not** require panel native 24 Hz.  
If someone bypasses ascal for direct 24 Hz HDMI, many panels reject it — **out of scope** unless parent orders that experiment.

---

## 5. Scope fence

| Netlist | clk_sys Fmax | Native 720p24 paper |
|---------|-------------:|---------------------|
| Stub-in | 23.46 (stub path) | min 23.18 **marginal/FAIL** slow |
| **Nostub ARM-present** | **32.59** residual_csum | **(a)(b)(c) CLEAR paper** |
| + full fabric H.264 | **UNKNOWN** | no STA |
| Raised-clk + native DE RTL | **UNKNOWN** | need fit |

---

## 6. STA gates (fit grant — parent only)

```text
NETLIST: PRODUCT_NO_STUB; decode_stub rows = 0
PLL:     out0 = 24.000000 MHz (preferred 720p24) OR 30.000000; out2 = 90.0; no HPS retune
BEAM:    DE 1280×720; H_TOTAL=1312; V_TOTAL=762 (or documented class)
CORNER:  Slow 1100mV 100C (+ report Fast; no Fast-only signoff)
ASSET:   24/1 content (not 30)

G1  Fmax(clk_sys) ≥ PLL target (24 or 30)
G2  setup slack @ target period ≥ 0 (constrained)
G3  Path #1 named; not decode_stub
G4  clk_sys↔clk_ddr related slack ≥ 0
G5  hierarchy: beam DE 1280 live; ascal on pll_hdmi (glass ~60)
G6  NEW_RBF ∉ banned; ONE menu deploy
G7  HDMI capture: 1280-class active; unique frame rate ~24 not ~20.7; no black

PRE-REG: HIT = all G1–G7 quoted; else NO-GO keep Route B
```

---

## 7. GO / NO-GO (revised)

| Claim | Verdict |
|-------|---------|
| Size native 720p at **30 fps** for rk=7 asset | **WRONG baseline** — asset is **24/1** |
| Parent 24.19 MHz | **OK for tight 1344×750 only**; not CEA VIC32 |
| CEA VIC 32 core beam (59.4 MHz) | **NO-GO** vs 32.59 |
| Min/tight/60-line @24 vs 32.59 nostub | **CONDITIONAL GO paper** (margins 29% / 26% / 9%) |
| Integer **24 MHz** + H=1312 V=762 | **Preferred CONDITIONAL GO** first fit |
| Integer **36 MHz** | unnecessary for 24; still ≤32.59 paper but no need |
| Fabric-decode-in | **NO-GO until STA** |
| Route B @20 MHz glass 720p | **Default until G1–G7** |
| `{705,706}` for this 24/1 native beam | **NOT required** (1:1) |
| Ship-proof today | **NO** — no raised-clk fit |

---

## 8. Module landing (mandatory fields)

| Module | ON_MAIN | IN_FILES_QIP (main) | Notes |
|--------|---------|---------------------|-------|
| `present_video_timing_720p.sv` | **no** | **no** | on `w-clock-bump` only; QIP yes on branch; **worth 0 to product until land** |
| `present_beam_content_de.sv` | **no** | **no** | product beam SoT; coordinate land after w-osd |
| `present_core.sv` | yes (stale) | yes | branch has native/B20 deltas |
| This packet (doc only) | n/a | n/a | `.agent-work/w-clock/` |

**No PLL/beam RTL applied for ship.** w-osd lands present path first (parent sequence).

---

## 9. Parent action when fit opens

1. Prefer **24 MHz + 1312×762 DE 1280×720** nostub ARM-present (720p24 asset).  
2. Optional compare: 30 MHz + 1312×953 (~24 Hz) if 24 MHz PLL path blocked.  
3. Do **not** claim CEA 720p24. Do **not** add fabric decoder same fit.  
4. Capture glass @60 HDMI via ascal; score unique content cadence ~24.  
5. Route B remains fallback.

---

## 10. Executable fit kit (parent handoff)

Directory: `.agent-work/w-clock/fit-native-720p24/`

| Artifact | Path |
|----------|------|
| **SDC (real text)** | `fit-native-720p24/Plex_native720p24.sdc` |
| **PLL edit (not applied)** | `fit-native-720p24/PLL_EDIT.md` — `pll_0002.v` `output_clock_frequency0` `"20.000000 MHz"` → `"24.000000 MHz"` |
| **STA assertions** | `fit-native-720p24/STA_PASS_CRITERIA.md` + `sta_pass_criteria.json` |
| **Risks** | `fit-native-720p24/RISKS.md` — **32.59 does not auto-survive** |
| **L0–L4 verify** | `fit-native-720p24/LADDER_VERIFY.md` |

**Corner that counts:** Slow **1100mV 100C Final**. Fast-only → reject.  
**Fmax floor:** clk_sys ≥ **24.000** MHz; path owner named; not `decode_stub`.
