# P3-WIDE RCA — HBlank@320 / DE / HDMI pillar

**Status:** eyes-on **FAIL OPEN** on every lab RBF to date. Gate **OPEN**. Do **not** mark P3-WIDE **DONE**.  
**RCA:** **FINALIZED** (W-rca → **W-rca6**).  
**Fix-1 silicon CLOSED (ineffective — not PASS):** state B (`aa146c17`) and state C (`820484a6`) both still `PILLAR_320_of_529` ~60.5% on eyes-on. **Do not redeploy expecting WIDE green. No more HSync-only thrash.**  
**Next:** **Fix-2 paint-full-DE@529** — design **LOCKED / READY** (**W-fix2-design → W-fix2-d3**). **R-csum1 BUILD_OK** (`dabdaeb0`) — Quartus free. Apply Fix-2 RTL when residual path allows (prefer not thrash residual RCA mid-edit; separate rebuild OK). Do **not** mid-edit residual csum sources for WIDE.  
**Reports:** `/tmp/misterplex-agent-W-wide.txt`…`W-wide6.txt`, `W-rca.txt`…`W-rca6.txt`, `W-proto7.txt`, `W-fix2-design.txt`, **`/tmp/misterplex-agent-W-fix2-d3.txt`**  
**Lab RBF (current):** `dabdaeb0` (full `dabdaeb0c5ae708c4fdbba388ba275b6`, H-deploy-rcsum1) — FBAR **PASS**; res_dc=-24 PASS; res_csum hard FAIL (H-rcsum-gate; separate ticket); **WIDE** last eyes-on **FAIL** ~60.5% on prior `820484a6` (**W-wide4 / W-wide5 / W-wide6**); Fix-2 design READY.

## Symptom

HDMI UVC 800×600 captures with `force_bars=1` / Pattern=Bars show active content only on the **left ~60.4%** of the frame (x≈2–484), solid black on the right.

That ratio is **exactly** \(320/529 \approx 0.6049\): content painted for `hc < 320` inside a **Template DE of 529**.

## Multi-agent WIDE FAIL confirmation (locked)

| Worker | Lab RBF | Claim | span | verdict |
|--------|---------|-------|-----:|---------|
| W-wide / W-wide2 | `6db3a4d8` | Template A class | ~60.5% | `PILLAR_320_of_529` |
| W-wide3 / W-wide3b | `aa146c17` | Fix-1 state B (HBlank@320, HSync 544/590) | ~60.5% | `PILLAR_320_of_529` |
| **W-wide4** | **`820484a6`** | Fix-1 state C (HBlank@320, HSync 336/384, level HBlank) | **60.5%** | `PILLAR_320_of_529` |
| **W-wide5** | **`820484a6`** | same (independent re-eye) | **60.5%** | `PILLAR_320_of_529` |
| **W-wide6** | **`820484a6`** | same (third reconfirm) | **60.5%** | `PILLAR_320_of_529` |

FBAR path is green on the same RBFs (bars force path OK). Failure class is **width/geometry**, not unlock/black and not force-bars mux.

**Fix-1 experiment closed as ineffective on silicon eyes-on.** No more HSync-only thrash. Prefer Fix-2.

## Timing (what the RTL is supposed to do)

| Parameter | Value | Role |
|-----------|------:|------|
| `H_CONTENT` | 320 | Product / frame_store width (stays 320 under Fix-2) |
| `H_LAST` | 637 | Line total 638 clocks |
| `H_BLANK_S` (Template A / pre-fix / **observed silicon**) | 529 | Template DE width |
| `H_BLANK_S` (state B / C source claim) | 320 | DE = content — **not observed** as full-width HDMI |
| `H_SYNC_S` .. `H_SYNC_E` (Template A) | 544 .. 590 | Proven FBAR-green class |
| `H_SYNC_S` .. `H_SYNC_E` (state C / `820484a6` source) | 336 .. 384 | Short FP after DE@320 — **WIDE still pillar** |

`VGA_DE = ~(HBlank | VBlank)` (`Plex.sv` ~L365). ascal measures DE and scales to HDMI. Default AR 4:3 matches 320×240 product content.

Bars (pre–Fix-2): `bar = px[8:6]` → 64-px slices; only bars 0–4 (W/Y/C/G/M) fit in 0..319. Red/blue never enter paint window.

## Why the pillar remains

Lab bar **edges** land at capture x ≈ \(hc \times 800/529\) for `hc ∈ {0,64,128,192,256,320}` → ends at **x≈484**, then black. That is black **inside DE**, not an ascal letterbox outside content.

| If bitstream had… | Expected HDMI | Lab |
|-------------------|---------------|-----|
| HBlank@529 + paint `hc<320` | ~60.4% span, 5 bars + black right | **Observed** on `6db3a4d8`, `aa146c17`, `820484a6` |
| HBlank@320 + paint fills DE | ≥~95% span, bars across full width | **Never observed** (states B and C) |
| HBlank@529 + paint fills DE 0..528 | ≥~95% span, 7 bars stretched | **Fix-2 target** (not yet built) |

So either:

1. **H1 reinforced (dominant):** silicon still **behaves as HBlank@529 + paint hc<320** despite source claims of HBlank@320 (states B and C). Exact 320/529 fingerprint across three RBFs.  
2. **H2 secondary:** HBlank@320 live but something else recreates the same geometry — still fails the full-width gate; Fix-2 does not depend on resolving H1 vs H2 because it paints the Template-wide DE class that eyes already measure.

`present_core` only forwards colorbars blanking; `mycore.v` (still HBlank@529) is not on the present path.

## Closed experiments

### State B — Q-3l1 / `aa146c17`

| Step | Result |
|-----:|--------|
| BUILD_OK + deploy | md5 **aa146c17…** |
| FBAR | PASS |
| Residual hard | res_dc=-24 PASS; **res_csum FAIL** (separate) |
| WIDE (W-wide3/3b) | **FAIL** frac≈0.605 `PILLAR_320_of_529` |

HBlank@320 + Template-late HSync@544: **ineffective** on silicon eyes-on.

### State C / Fix-1 — Q-fix1 / `820484a6`  ★ CLOSED FAIL (ineffective — not PASS)

Source claim (absorbed into Q-fix1; **current tree `colorbars.sv` still matches**):

```text
H_BLANK_S = H_CONTENT          // 320
H_SYNC_S  = 336, H_SYNC_E = 384
HBlank   <= (hc >= H_BLANK_S)  // level
```

| Worker | Result |
|--------|--------|
| W-wide4 | FAIL span=60.5% R5%=0 |
| W-wide5 | FAIL span=60.5% R5%=0 |
| W-wide6 | FAIL span=60.5% R5%=0 |

Indistinguishable from Template A fingerprint. **Do not redeploy `820484a6` expecting WIDE green.** **Do not thrash more HSync-only variants.** **Fix-1 is closed as ineffective (experiment FAIL), not as WIDE PASS.**

## Fix-2 design (LOCKED — W-fix2-d3) — paint-full-DE@529

**Intent:** Keep **Template A timing** (FBAR-proven DE-class) and **paint the entire DE** so force-bars HDMI span ≥95%. Product `frame_store` stays 320×240 left-aligned until a later width ticket.

### Timing constants (Template A / mycore-class)

| Symbol | Value | Notes |
|--------|------:|-------|
| `H_CONTENT` | `10'd320` | Product / frame_store only; **not** DE width under Fix-2 |
| `H_DE` / `H_BLANK_S` | `10'd529` | Active DE width; blank starts at hc≥529 |
| `H_LAST` | `10'd637` | 638 clocks/line (leave alone; FPS) |
| `H_SYNC_S` | `10'd544` | Template |
| `H_SYNC_E` | `10'd590` | Pulse width 46 clocks (Template) |
| HBlank style | edge **or** level | Prefer level `HBlank <= (hc >= 529)` (clear); edge Template OK |

VBlank/VSync remain keyed off HSync start as today (NTSC/PAL scandouble tables unchanged).

### Paint bounds

| Signal | Pre–Fix-2 (pillar) | Fix-2 |
|--------|-------------------|-------|
| `in_content` (colorbar paint) | `hc < H_CONTENT` (320) | `hc < H_DE` (**529**) i.e. hc ∈ **0..528** |
| Vertical | `py < 240` | unchanged |
| Blank gate | `~HBlank && ~VBlank` | unchanged |
| `bar` (pattern 0/1) | `px[8:6]` (64-px; 5 bars) | **stretch 7 bars across DE** |

**Bar stretch (concrete):**

```text
// Integer scale: 7 equal slices over DE width 529
// bar ∈ {0..6} for hc ∈ {0..528}
wire [12:0] bar_prod = hc * 4'd7;     // 0 .. 3696  (< 8192)
wire [2:0]  bar      = bar_prod / H_DE; // 0..6 (hc=528 → 3696/529=6)
```

Expected slice starts (floor):  
hc boundaries ≈ 0, 76, 151, 227, 302, 378, 453, 529  
→ colors W / Y / C / G / M / **R** / **B** all enter the paint window (lab today stops at magenta).

Threshold form (no divider, optional implementer choice):

```text
// approx equal ~75–76 px slices (same visual intent)
// 0:[0..75] 1:[76..151] 2:[152..226] 3:[227..302]
// 4:[303..377] 5:[378..453] 6:[454..528]
```

Grid (`px[3]^py[3]`) and ramp (`px[7:0]`) automatically fill DE once `in_content` uses hc&lt;529.

Moving block (pattern 1): leave position math on `content_index`; still valid inside expanded paint window.

### Concrete RTL touch points (implementer checklist)

**Source of truth for line numbers:** tree at design lock time (Fix-1 state C still on disk while R-csum1 fits residual). Lines may shift ± a few after other commits — match by **symbol/comment**, not only line #.

#### 1. PRIMARY — `fpga/Plex_MiSTer/rtl/colorbars.sv`

| Region (approx L#) | Current (state C / Fix-1) | Fix-2 action |
|--------------------|---------------------------|--------------|
| **L1–6** header | Claims “Do NOT use Template HBlank@529 with only 320px paint” | Rewrite: Fix-2 keeps HBlank@529 **and paints full DE**; note Fix-1 `820484a6` WIDE FAIL closed |
| **L29–39** localparams | `H_CONTENT=320`; `H_FP=16`; `H_SYNC=48`; `H_BLANK_S=H_CONTENT` (320); `H_SYNC_S=336`; `H_SYNC_E=384` | Replace with Template: `H_CONTENT=320` **keep**; add `H_DE=529`; `H_BLANK_S=H_DE`; `H_SYNC_S=544`; `H_SYNC_E=590`; drop/leave-unused `H_FP`/`H_SYNC` derived path |
| **L33** `H_LAST` | `10'd637` | **Leave alone** (FPS / 638 clocks) |
| **L79–87** HBlank | comment “Level HBlank so DE never stretches past H_CONTENT”; `HBlank <= (hc >= H_BLANK_S)` | Keep level form; now `H_BLANK_S=529`. Update comment → DE width 529 |
| **L89–92** HSync edges | fire at `H_SYNC_S`/`H_SYNC_E` | Unchanged pattern; constants become 544/590 |
| **L94–117** VBlank/VSync | keyed off `hc == H_SYNC_S` | **Leave tables alone**; auto-follow new H_SYNC_S=544 |
| **L121–127** paint | `bar = px[8:6]`; `in_content = (hc < H_CONTENT) && …` | `bar = (hc * 7) / H_DE`; `in_content = (hc < H_DE) && (py < 240) && ~HBlank && ~VBlank` |
| **L129–142** `case(bar)` colors | 0..6 W/Y/C/G/M/R/B | **Unchanged** (R/B become reachable) |
| **L144–148** moving block | `bx`/`by` from `content_index` | **Leave** |
| **L150** grid | `px[3]^py[3]` | **Leave** (auto-fills DE once paint expands) |
| **L152–178** pattern mux | uses `in_content` | **Leave body**; inherits expanded window |

**Diff-intent sketch (paste reference only — do not apply mid-fit):**

```systemverilog
// Fix-2: Template HBlank@529 + HSync 544/590 (FBAR-proven) with paint
// across full DE (hc 0..528). Fix-1 HBlank@320 / HSync 336/384 was
// ineffective on silicon eyes-on (still PILLAR_320_of_529 on 820484a6).
// frame_store remains 320; present_core active window stays hc<320.

localparam H_CONTENT = 10'd320;  // product / frame_store only
localparam H_DE      = 10'd529;  // Template active DE width
localparam H_LAST    = 10'd637;  // 638 clocks/line — UNCHANGED
localparam H_BLANK_S = H_DE;     // 529
localparam H_SYNC_S  = 10'd544;  // Template
localparam H_SYNC_E  = 10'd590;  // Template

// blanking block (level preferred):
HBlank <= (hc >= H_BLANK_S);

// paint:
wire [9:0] px = hc;
wire [9:0] py = scandouble ? (vc >> 1) : vc;
wire [12:0] bar_prod = hc * 4'd7;
wire [2:0]  bar      = bar_prod / H_DE;
wire in_content = (hc < H_DE) && (py < 10'd240) && ~HBlank && ~VBlank;
// case(bar) / pattern mux / block / grid / ramp — unchanged
```

#### 2. COMMENTS ONLY — `fpga/Plex_MiSTer/rtl/present_core.sv`

| Region (approx L#) | Current | Fix-2 action |
|--------------------|---------|--------------|
| **L90–108** hc/vc reconstruct | matches colorbars `H_LAST=637` | **No functional change** |
| **L110–111** `active` | `hc < 10'd320` | **KEEP** — frame_store read window stays 320 left-aligned |
| **L120–123** `frame_store` WIDTH/HEIGHT | 320 / 240 | **KEEP** |
| **L146–150** `force_bars` / RGB mux | O[9] / pattern force | **DO NOT TOUCH** |
| **L152–157** blanking assign | pass-through colorbars | **KEEP** |

Optional comment near L110:

```text
// colorbars paint window is H_DE (529) under Fix-2; store remains 320 left-aligned.
// WIDE gate is measured under force_bars=1 (colorbar path fills DE).
```

#### 3. DO NOT TOUCH (this ticket)

| File / region | Why |
|---------------|-----|
| `fpga/Plex_MiSTer/Plex.sv` (O[9] mux ~L330–335, `VGA_DE` ~L365) | **R-csum1 owns residual mid-fit**; O[9]/DE out of WIDE scope |
| `fpga/Plex_MiSTer/rtl/mycore.v` (HBlank@529 leftover) | Not on present path |
| `frame_store.sv` WIDTH | Later product-width ticket |
| `sys/ascal` / AR / video_freak | Not root cause; FBAR green |
| Any mid-fit write under `fpga/Plex_MiSTer/` while quartus_fit LIVE | Race residual rebuild |

### FBAR / lock risk

| Change | Risk |
|--------|------|
| Fix-2 paint-full-DE @ HBlank@529 + HSync 544/590 | **Low** — timing matches FBAR-green Template class |
| Further HSync-only variants after Fix-1 FAIL | **Avoid** — wasted; lock risk without geometry win |
| O[9] force_bars mux edits | **High** — out of scope |
| Expanding frame_store to 529 | **Out of scope** — later width ticket |

Always: one deploy → **FBAR green** → WIDE span check → park bars force=1 NTSC 60.

### Acceptance (WIDE) — do not invent PASS

PASS only if **all** of:

- `force_bars=1` bars NTSC 60  
- mid-band active span **frac ≥ 0.95** of capture width  
- R5% mid-band luma **> 15**  
- verdict **≠** `PILLAR_320_of_529`  
- FBAR still EXIT=0 on the **same** RBF  

FAIL if still ~60.5% (paint not absorbed / wrong RBF) or unlock/black (unexpected for Fix-2 timing).

Capture method (W-wide3): MacroSilicon UVC `/dev/video4`; warm frames (discard cold mean≈7 stubs); MJPG 800×600 + YUYV 800×600 + MJPG 1920×1080 cross-check.

Expected PASS signature under Fix-2:

- span ≳ 95% (full DE painted; ascal scales full DE)  
- **7** SMPTE-style bars visible (R and B enter window)  
- R5% ≫ 15 (right edge is bar, not black pillar)  
- bar edges every ~114 capture-px (800/7), not every ~97 (800×64/529)

Diagnostic bonus (not hard gate): all 7 bars + red/blue enter paint → proves paint past hc=320 on 529-class DE.

If still `PILLAR_320_of_529` after a real Fix-2 RBF:

1. Verify RBF md5 / CORENAME / force_bars live  
2. Confirm colorbars.sv absorbed (H_DE paint + bar×7/529; clean Full Compilation preferred over smart recomp skip)  
3. Only then deeper ascal / sys_top DE RCA  
4. **Do NOT** return to Fix-1 HSync thrash as first resort  

### Sequencing (orchestrator)

1. **R-csum1** sole rebuild LIVE → wait real **BUILD_OK** + collect (**do not invent**).  
2. Sole deploy → FBAR re-confirm → hard res_csum gate (Open #1).  
3. **Then** Fix-2 RTL apply + sole rebuild (or combine only if policy allows one free Quartus slot and sources are staged carefully). Prefer **sole colorbars-focused rebuild** so residual pack does not silently drop paint.  
4. One deploy of Fix-2 RBF → FBAR → WIDE eyes-on → park.  
5. **No** Quartus / deploy / new lab captures required from this design docs worker.

**While R-csum1 fit LIVE:** **zero** edits under `fpga/Plex_MiSTer/` that race the csum rebuild (especially dirty `Plex.sv`). Docs-only design ticks are safe during fit.

## Pass criteria (gate)

- `force_bars=1` bars NTSC 60: active span **≥ ~95%** of capture width; not `PILLAR_320_of_529`.  
- FBAR still EXIT=0 on same RBF.  
- Optional: true VGA/CRT eyes-on (HDMI is a proxy; see [crt-lcd-lab-checklist.md](crt-lcd-lab-checklist.md)).

## Historical notes (Q-3l1 mid-fit hygiene)

| Artifact | Time (CDT) | colorbars state |
|----------|------------|-----------------|
| Q-3l1 Analysis map | ~11:34 | state B (HBlank@320, HSync@544) |
| Dirty WIP write | ~11:41 | state C (HSync@336/384 + level HBlank) |
| Q-3l1 BUILD_OK | 11:45 | RBF **aa146c17** = state B (smart recomp skipped C) |
| Q-fix1 BUILD_OK | 12:02 | RBF **820484a6** = Fix-1 state C claim — **WIDE still FAIL** (W-wide4/5/6) |
| W-fix2-d3 design lock | ~12:13 | Fix-2 plan locked; RTL deferred (R-csum1 fit LIVE) |

Leave `fpga/Plex_MiSTer/` alone while any fitter runs. Docs-only design ticks are safe during fit.
