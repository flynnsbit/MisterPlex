# Frame-rate cadence at 720p presentation (Route B)

**Lane:** w-clock · **No fit · No device**  
**Measured vs inferred** labeled. awk true arithmetic (no bc).

---

## What “720p presentation” means here (measured architecture)

Route B (accepted): **core beam is not a native 1280×720 raster.**

| Layer | What runs | Source |
|-------|-----------|--------|
| Content DE | ≤ **960×540** true-DE (cap in `present_core` `RT_MAX_*`) | `present_core.sv` RT_MAX_HDE/VACT |
| Line class | **H_TOTAL = 1182** fixed @ **clk_sys 20 MHz** | `beam_htot_req = 11'd1182` |
| V class | Bresenham **{705,706}** film / **{564,565}** TV | `present_vtotal_bresenham.sv` |
| Glass 1280×720 | **ascal** upscale + ARX/ARY pillar | sys_top / ascal; lowlat default **0** (triple-buffer class) |

Native 1280×720 beam @20 MHz is **dead** (min-blank 1312×736 → **20.71 Hz**; 24 fps needs ≥23.18 MHz on that geometry). Cadence work is on the **content beam**, not a 720p pixel clock.

---

## Pre-register (before awk)

| ID | Prediction | Score |
|----|------------|-------|
| P1 | Product film long-run @ H=1182 needs mean V = 1251250/1773 ≈ **705.72476** | |
| P2 | Duty **0.72476 is fraction of frames at V=706**, not 705 (parent wording inverted) | |
| P3 | Exact long-run err vs 24000/1001 is **0** (double) with that mean | |
| P4 | One-line jitter = 1182/20e6 = **59.1 µs** | |
| P5 | 720p glass does **not** change H_TOTAL pair — same Bresenham as SD content path | |
| P6 | fstart-ack and Bresenham both edge on fstart; dither does **not** break swap gating | |

---

## Measured arithmetic (awk, true)

```
clk=20e6  H=1182
NTSC film: meanV=705.7247602933  duty@706=0.7247602933
  hz = 20e6/(1182*meanV) = 23.976023976024 = 24000/1001   err=0
NTSC tv:   meanV=564.5798082346  duty@565=0.5798082346
  hz = 29.970029970030 = 30000/1001                         err=0
exact 24:  meanV=705.0197405527  duty@706=0.0197405527     hz=24 exact
exact 30:  meanV=564.0157924422  duty@565=0.0157924422     hz=30 exact
jitter   = H/clk = 59.1000 µs
fixed V=705 slip vs NTSC film: 1/(24.000672−23.976024) ≈ 40.57 s
fixed V=564 slip vs NTSC tv:   ≈ 32.46 s
```

**P1–P4 HIT.** Parent’s “72.48% at 705” is the **complement** miss already fenced in module header (`PARENT MISS`).

Product default duties are **NTSC** (`NTSC_FILM_NUM=1285`, `NTSC_TV_NUM=1028` over `DEN=1773`). Exact integer 24/30 needs `FAULT_BRES_EXACT_INT` or a future awarded family bit — q5 still cannot distinguish (bit34 RESERVED).

**P5 HIT (by architecture, not new STA):** 720p is ascal output mode; beam totals stay 1182×V. No second Bresenham table for “720p.”

---

## Does 720p need a different dither?

| Question | Answer |
|----------|--------|
| Integer V_TOTAL hit exact 23.976 @ H=1182? | **No** — need non-integer mean → **2-value dither required** |
| Same pair as SD? | **Yes** — rate = clk/(H·V); H and clk unchanged by glass mode |
| CEA 1280×720@60 HDMI timing on core beam? | **No** — that is HDMI PLL + ascal output; core stays content cadence |

If multi-pixel / native 720p beam were ever revived (not product): H_TOTAL would change and the entire {705,706}/1773 table would be **invalid** — re-derive meanV = clk/(rate·H_new). **Not scheduled.**

---

## Interaction with fstart-ack (`77eac03c`)

Quoted product path (`present_core.sv`):

```text
visual_swap_ack = frame_start && swap_pending && store_pending_ready;
// Bresenham: .frame_tick(fstart)
// beam: rt_vtotal from bres; V_TOTAL latches every v_wrap; DE only if rt_de_apply
```

| Mechanism | Clock edge | Effect of V∈{705,706} |
|-----------|------------|------------------------|
| Bresenham `frame_tick` | `fstart` | Chooses **next** frame’s V_TOTAL |
| Beam V latch | `v_wrap` / fstart | Period of **this** scan is already-latched V |
| `visual_swap_ack` | same `frame_start` | Bank/app shadows promote only on **real swap edge** |
| Mid-active `pending_ready` | — | Still must **not** promote (ack requires fstart) |

**P6 HIT (logic, TB-covered for ack; dither×ack co-sim not a new gate this turn):**

- Dither changes **time between** fstarts by 0 or +1 line (**±0 / +59.1 µs**), not the ack boolean.
- Longer film frames slightly delay the next swap opportunity — still one opportunity per beam frame; ARM `swap_pending` unchanged.
- ascal `lowlat=0` triple-buffer class is the intended absorber of one-line period jitter (design claim; **HDMI absorb not re-measured this turn** — parent capture when device is up).
- **B15 still not closable on wire:** swap remains `fstart && swap_pending` (and ready), **not** `advance`. Bresenham locks **beam wall-clock rate**; unique bank rate still needs ARM publish policy.

**No code change required** for 720p cadence beyond the existing Bresenham path already wired for BEAM_960 / content DE.

---

## What parent can test on HDMI (when device returns)

1. Film title, NTSC 23.976: long-haul A/V — expect **no** +1 frame / 40.57 s slip if Bresenham enabled and ARM publishes at source rate.  
2. Fault twin `FAULT_FIXED_VTOTAL`: should **show** judder/slip class (red).  
3. Do **not** expect core DE 1280 wide — capture content window + ascal pillar per DAR.

---

## Honesty fence

- **Measured this turn:** PLL parameter strings; present_core H=1182 / RT_MAX; bres module duties; awk long-run err=0; fstart-ack expression.  
- **Inferred:** ascal absorbs 59.1 µs (from lowlat=0 + prior Route B); VCO 360 class from prior STA notes.  
- **Unknown until device:** visible judder score on glass.  
- **Unknown until CAVLC measure:** whether any decode PLL is needed at all (see `DECODE_PLL_FEASIBILITY_ENVELOPE.md`).
