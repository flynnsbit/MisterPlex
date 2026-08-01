# Design: output-raster player chrome plane (option c)

**Status:** paper design only — **no Quartus fit requested or started.**  
**Branch context:** `w-osd-hires`. ARM bank chrome stays for pre-RBF deploy (black-rect etc.).

**User requirement:** player/timeline chrome must match **MiSTer output resolution**, not
streaming/DECODE geometry, and must **scale down** correctly at 800×600, 640×480, 240p.

**Settled non-goals:** font pick on 624×480 bank (already 12×16); `bodyScale=3` placebo.

---

## 0. Constraints (binding)

| Constraint | Value | Source |
|---|---|---|
| Present fetch | `V_STORE=240`, `STORE_Y_SCALE=2.0` exact | `present_core.sv:161-164` |
| Content bank | coded 624×480 | `ddr_frame_layout_params.svh` |
| Live HDMI (device) | `video_mode=12` → **1920×1440@60** | parent measured `MiSTer.ini` |
| Free M10K | **88 blocks** (553−465); **use block counts, not bits** | parent fit baseline |
| Free ALM / DSP | 41,910−21,095 = **20,815 ALM**; 112−74 = **38 DSP** | parent baseline |
| Fit slot | **closed** until discriminating gate exists | parent |

**Arithmetic that must not be repeated:** 88 × 10240 bits ≈ 901 kbit ≈ 110 KiB usable.
A full 1920×1440 RGB565 plane is ~5.3 MiB ≈ **4300 M10K** — impossible on-chip.

---

## 1. Where the plane lives

### Existing hook (evidence)

MiSTer already composites **after** ascal on the HDMI path:

```text
ascal → (mask) → osd hdmi_osd → HDMI pins
sys_top.v ~714 ascal, ~1183 osd hdmi_osd
```

`osd.v` blends on `clk_video` using `de_in`/`din`/`dout`, and sizes itself from
**measured DE width** (`dsp_width` on DE falling edge) — i.e. **output raster**, not
the core’s 529×240 content DE.

Framework `osd` is only a **256×64** (plus highres) **4 KiB** F12 menu buffer
(`OSD_WIDTH/HEIGHT`, `osd_buffer[4096]`). It is the **right pipeline stage** and the
**wrong capacity** for player chrome.

### Proposed insertion

```text
ascal → plex_chrome (NEW) → osd hdmi_osd → HDMI
         ↑
    clk_hdmi, de/hs/vs, RGB24 video
    hdmi_width / hdmi_height (sys_top already tracks these)
```

- **Not** inside `present_core` / F1 bank (that is the bug).
- **Not** a second full-frame DDR scanout competing every cycle with video unless
  forced (see §3 escape hatch).
- VGA path: mirror `plex_chrome` on the VGA post-scale leg the same way dual `osd`
  instances already exist for HDMI vs VGA in `sys_top.v`.

**Geometry source of truth (RTL):** `WIDTH`/`HEIGHT` (or `hdmi_width`/`hdmi_height`)
from the scaler programming path (`sys_top.v` ~896–910, 1053–1057). ARM may also
read `[Plex] video_mode` / future status word for layout preview; **scanout must not
trust ARM** — pixel counters on DE are authoritative (same pattern as `osd.v`).

---

## 2. Architecture choice inside 88 M10K

### Rejected: full-frame on-chip FB

| Buffer | ~M10K @ 10 kbit |
|---|---:|
| 1920×1440 RGB565 | ~4300 |
| 1920×1080 A8 | ~1620 |
| 529×240 RGB565 (pre-ascal DE) | ~198 |

All **> 88**. Pre-ascal DE plane also **fails the user**: still not HDMI resolution.

### Rejected as primary: full-frame DDR overlay every pixel

Possible in principle (second DDR reader + line FIFO), but:

- Contends with F1 `ddr_frame_store` on the same DDRAM port during active video.
- Needs multi-line prefetch FIFOs (several 1920×RGB entries) and a second bank protocol.
- Higher ALM + timing risk; three fits already lost this session class.

Keep as **escape hatch** (§3.2) if display-list cannot express future art.

### Selected primary: **display-list glyph rasterizer** (output-pixel clock)

ARM does **not** paint chrome into the 624×480 YUV bank for the product path.
ARM emits a **compact display list**; RTL expands glyphs/icons during HDMI scanout
at 1:1 with output pixels.

```text
┌──────────── ARM (misterplexd) ─────────────┐
│ layoutMetrics(outW,outH)  // OUTPUT raster │
│ build list: panel, icon, glyphs, bar, …    │
│ write list → small DDR mailbox OR SPI      │
└───────────────────┬────────────────────────┘
                    │ double-buffered list
┌───────────────────▼────────────────────────┐
│ plex_chrome.sv (clk_hdmi)                  │
│  font ROM + icon ROM (M10K)                │
│  active list RAM (M10K)                    │
│  per-pixel: hit-test spans → blend RGB     │
└───────────────────┬────────────────────────┘
                    │ RGB out
                 hdmi_osd → pins
```

**Why this meets the user:**

- Every chrome sample is an **output pixel** (or integer scale of a glyph cell), never
  a 624×480 texel stretched 3×.
- Same list builder uses `outW,outH` from live mode → **800×600 / 640×480 / 240p**
  automatically shrink margins, `bodyScale`, panel height (fractional layout, snap even).
- Even-row cull in `present_core` is **irrelevant** to chrome (chrome never enters F1).

---

## 3. Storage and fetch within 88 M10K

### 3.1 Primary budget (display-list)

| Block | Contents | Est. M10K | Notes |
|---|---|---:|---|
| Font ROM A | 12×16, 96 glyphs, 1 bpp | **2** | 96×12×16 = 18432 bit |
| Font ROM B | 8×13, 96 glyphs, 1 bpp | **1** | dense small modes |
| Icon ROM | 8 icons × 32×32 × 1 bpp | **1** | play/pause/stop/skip |
| List RAM 0/1 | 2× 512 × 64-bit commands | **8** | double-buffer; see ISA |
| Span index | optional y→cmd run length | **4** | speed up per-line walk |
| Blend pipeline regs | not BRAM | 0 | flops |
| **Subtotal primary** | | **≤16** | **72 blocks still free** |
| Margin / fit risk | leave unused | **≥40** | do not spend “because free” |

**Command ISA (64-bit, illustrative):**

| opcode | payload |
|---|---|
| `RECT` | x,y,w,h, rgba8 (panel fill / bar track) |
| `GLYPH` | x,y, code, font_id, scale(1..8), rgba8 |
| `ICON` | x,y, id, scale, rgba8 |
| `END` | — |

Worst-case pause UI ≈ 1 panel + 1 icon + ~20 glyphs + 2 bar rects + knob ≪ 512.

**Per-pixel work (HDMI ce_pix):**

1. Maintain `hx,hy` from DE (copy `osd.v` counter style).
2. For current `hy`, walk span list (or scan active cmds) — **bounded** (e.g. ≤32
   active cmds/line) so timing closes at 148.5 MHz-class HDMI clocks.
3. Glyph: `row = (hy-y)/scale`, `bit = font_rom[code][row][col]`, blend if set.
4. Output `rgb = bit ? fg : din` (opaque) or alpha blend if needed later.

**Integer scale only** (1..8): no DSP required for text. Bar width uses
`(position*bar_w)/duration` — one 24×12 multiplier → **≤2 DSP** worst case, or
ARM precomputes fill_w into the list (**0 DSP** preferred).

### 3.2 Escape hatch (not for first fit): DDR panel strip

If a future design needs photographic art under chrome:

- Store **only the panel band** in DDR (e.g. full width × panel_h × A8).
- At 1920×(0.2×1440) A8 ≈ 1920×288 ≈ 540 KiB DDR — fine externally.
- M10K: **2× line FIFO** 1920×8bit ≈ **4 M10K** + fetch FSM (~1–2k ALM).
- Still composite **after** ascal; geometry from `hdmi_height`.
- **Do not** enable in first chrome RBF unless list path fails a gate.

---

## 4. Layout model (output raster, scales down)

Reuse the ARM mental model, but pass **HDMI W×H** (not 624×480):

```text
margin   = max(6, W/40)
bodyScale = clamp(2 .. 8, round(H / 240))   // 240p→2, 480p→2, 720→3, 1080→4–5, 1440→6
font     = bodyScale>=3 ? 12x16 : 8x13     // or always 12x16 when H>=480
panelH   = snap_even(clamp(frac*H, min_need(bodyScale), H/3))
panelY   = H - panelH - margin   // snap even
```

| Output (examples) | bodyScale (proposal) | PAUSED advance (12×16) | Notes |
|---|---:|---:|---|
| 1920×1440 (mode 12) | 6 | 13×6 = **78 px** | sharp; similar *size* to today’s stretched 80 px advance, not mush |
| 1920×1080 (mode 8) | 4–5 | 52–65 px | |
| 1280×720 | 3 | 39 px | |
| 800×600 | 2–3 | 26–39 px | must not clip panel |
| 640×480 | 2 | 26 px | |
| ~320×240 | 2 (floor) | 26 px | panel fractions shrink; gate must prove no overflow |

**Critical:** advance is in **output pixels**. Today’s silicon advance ~77 px is
`13*2*(1920/624)` — **upscaled bank texels**. After (c), advance is `13*bodyScale`
with **no** 3.08× bank stretch; edges stay binary-sharp under the grabber.

ARM stops calling `overlay_.renderYuv420p` on the F1 path for transport chrome once
the plane is live (feature bit / conf). Until RBF ships, keep bank chrome.

---

## 5. Cost estimate (pre-fit, reasoned — not tape-out)

| Resource | Estimate | Reasoning | Headroom vs free |
|---|---|---|---|
| **M10K** | **16–24** used by chrome | §3.1 table + 50% packing waste | 88 free → **≥64 remain** if ≤24 |
| **ALM** | **1.5k–4k** | `osd.v`-class counters + bounded cmd walk + blend; glyph bit extract | 20.8k free |
| **DSP** | **0–2** | Prefer ARM-precomputed bar fill; else one mult | 38 free |
| **DDRAM** | list only (~4–8 KiB) | Negligible vs F1 frame | — |
| **Fmax** | must meet existing HDMI clock | Bound cmds/line; pipeline blend 2–3 stages | gate in STA |

**Hard fail before fit grant:** any revision that needs **>40 M10K** for chrome, or
full-frame BRAM, or unbounded per-pixel DRAM.

These numbers are **engineering estimates** from structure + M10K math, **not** a
Quartus map. First fit must publish actual ALM/DSP/RAM delta vs baseline
21,095 / 74 / 465.

---

## 6. Software / protocol (ARM)

1. Detect plane live: status bit or conf `CHROME_PLANE=1` after BUILD_OK.
2. `layoutMetrics(hdmi_w, hdmi_h)` — read mode via ini parse and/or new SPI status
   mirroring `WIDTH/HEIGHT` (ini alone is OK for v1 if parent sets mode statically).
3. Build list each pause/play/seek UI event; double-buffer flip on vsync mailbox.
4. **Stop** compositing transport into YUV bank when plane active (avoid double draw).
5. Idle STOPPED chrome: same list path (not `paintIdle` RGB→YUV into F1).

---

## 7. Discriminating gates (must exist before exclusive slot)

### G0 — Host (no RBF): layout scales down

```bash
# synthetic: build list / metrics for W,H in {1920x1440,800x600,640x480,320x240}
# PASS: panel fully inside [0,W)×[0,H); bodyScale monotonic in H; min scale>=2
# FAIL: overflow or scale ignores H
python3 tests/unit/test_chrome_output_layout_static.py; echo "true rc=$?"
```

*(Implement with metrics-only C++/Python mirror of §4 before RTL.)*

### G1 — Host red/green: bank stretch vs output paint (conceptual)

| Arm | Method | PAUSED mean glyph advance @1920 grabber-equivalent |
|---|---|---|
| **RED (today)** | bank 12×16@2 → scale ×(1920/624) | **~77–80** soft edges (ascal) |
| **GREEN (c)** | list 12×16@scale=6 at 1920 | **78** but **binary** edges / template score ≥ bank |

Discriminate with **edge sharpness** (gradient magnitude on glyph stems), not advance
alone — advance can match by coincidence (today ~77 vs scale6=78).

### G2 — Silicon (after RBF only) — pre-register

| ID | Prediction | PASS | FAIL |
|---|---|---|---|
| **S-sharp** | Stem edge width ≤ 2 grabber px at mode 12 | median edge ≤2 | ≥4 (today’s mush) |
| **S-adv** | Advance ≈ 13×bodyScale(H) | within 10% | matches 13×2×(1920/624) **and** soft edges |
| **S-240** | Force mode 6 or lab 240p | panel on-screen, no clip | overflow / unreadable |
| **S-bank** | F1 YUV without list still plays video | video OK | video regression |
| **S-area** | Post-fit | RAM ≤465+40, no neg slack | RAM >40 delta or STA fail |

**Falsify (c):** sharp gate PASS but user still sees bank-sync softness tied to
`present_core` even-row (would mean chrome still on F1).

### G3 — Area pre-reg (fit grant checklist)

Before exclusive slot:

1. Quartus map (or hierarchical synth) of `plex_chrome` alone → M10K/ALM/DSP.
2. Must show **M10K ≤ 40**, **ALM ≤ 5k**, **DSP ≤ 4**.
3. Full core fit delta vs baseline 21095/74/465 published.
4. G0 green on host; sim of cmd walker at 148.5 MHz-class (or timed path report).

---

## 8. Phased delivery

| Phase | Deliverable | Fit? |
|---|---|---|
| **P0 (now)** | This design + G0 layout unit; ARM black-rect deploy | No |
| **P1** | `plex_chrome` RTL + font ROM + list RAM; sim walker | No exclusive until G0+unit |
| **P2** | Wire post-ascal; ARM list writer; feature bit | **One** exclusive fit |
| **P3** | Multi-mode lab (12, 8, 5, 6, 240p); retire F1 chrome | Parent scores pixels |

---

## 9. Recommendation (one paragraph)

Implement **post-ascal `plex_chrome`** as a **display-list glyph/icon rasterizer** with
font/icon ROMs and a double-buffered command list in **≤24 M10K**, **0–2 DSP**,
**~2–4k ALM**, composited on `clk_hdmi` using DE-derived coordinates from the **output
raster**. Derive layout from `hdmi_width/height` so 800×600 / 640×480 / 240p shrink
correctly. Do **not** enlarge F1 or raise `bodyScale` on the bank path as the product
fix. Grant a fit only after G0 + solo-module area numbers beat the §7 ceilings.

---

## 10. References

- `present_core.sv:161-164` — V_STORE / STORE_Y_SCALE ceiling  
- `sys_top.v` ascal + `osd hdmi_osd` — post-scale composite precedent  
- `sys/osd.v` — DE-relative blend pattern (capacity too small)  
- `docs/osd-output-raster-feasibility.md` — option table  
- `docs/osd-hires.md` — bank chrome / even-row history  
- Parent: `video_mode=12` = 1920×1440; free RAM **88 M10K blocks**
