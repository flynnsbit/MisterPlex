# Post-scale chrome plane (option c) — costed RTL design

**Status:** paper design only. **No fit. Slot closed.**  
**Branch:** `w-fit-integ-c5382bee-dequant-swap` (docs ride; does not claim BUILD_OK).  
**Depends on:** parent acceptance of (c) from `docs/osd-output-raster-feasibility.md` (`1c531e3f`); working core `c5382bee` undisturbed.

**User requirement:** on-screen player/idle chrome must match **MiSTer output resolution**, not streaming/content geometry.

---

## Baseline constraints (quoted / parent-measured)

| Item | Value | Source |
|------|------:|--------|
| ALM / DSP / RAM | 21 095 / 74 / **465/553** | parent fit baseline |
| M10K free | **88** (= 553−465) | derived from parent RAM |
| M10K capacity | **10 240 bits = 1 280 B** per block | Cyclone V M10K; same 1280 B/block used in feasibility doc |
| Free on-chip bytes | **88 × 1280 = 112 640 B** | derived |
| Product `FRAME_W/H` | **640 / 480** (presented) | `Plex.qsf:83-84` — **not** 624 |
| Product line prefetch | `FRAME_LINES_8=1` | `Plex.qsf:85` |
| DDR content bank | 624×480 coded YUV | `ddr_frame_layout_params.svh:5-6` |
| Vertical samples to display | **240 even store rows** | `present_core.sv:161-198`; see `docs/chrome-240-verify-and-inc1.md` |
| `clk_sys` / `clk_ddr` | 20.000 / **90.000 MHz** | `pll_0002.v` `output_clock_frequency0/2` |
| Live HDMI (parent) | `video_mode=12` → **1920×1440@60** | parent device read |
| Grabber archives | often 1920×1080 | feasibility doc (mode 8 vs 12 not unique from PNG alone) |

---

## F1 — Design: post-scale chrome plane

### F1.1 Where the composite tap goes (critical)

There are **two** scale stages today:

```
ARM chrome+video → DDR F1 (624×480)
       → present_core store_x/store_y scale into colorbars DE (H_DE=529, V_STORE=240)
       → emu RGB @ clk_sys
       → ascal (sys_top) → HDMI WxH @ clk_hdmi
       → shadowmask → osd (framework F12 menu) → HDMI_TX
```

**Wrong tap (does NOT meet user):** blend inside `present_core` after `fr,fg,fb` mux (`present_core.sv` ~384–386) but **before** `ascal`. Chrome would still be authored/composited on the **core/DE raster** and then **upscaled by ascal** → soft edges at 1920×1440.

**Correct tap (meets user):** blend on **`clk_hdmi` after `ascal`**, in the same neighborhood as framework `osd`:

| Stage | File:lines (product tree) | Role |
|-------|---------------------------|------|
| ascal out | `sys_top.v` ~714–768 | `hdmi_data`, `hdmi_hs/vs/de`, `o_clk=clk_hdmi` |
| shadowmask | ~1170–1188 | `hdmi_data_mask` |
| **Plex chrome blender (NEW)** | **insert here** | key/alpha over video |
| framework `osd` | ~1189–1205 | F12 menu only (`OSD_WIDTH=256`, `OSD_HEIGHT=64` in `osd.v:26-27`) — **not** player chrome |

Recommended order: **ascal → shadowmask → plex_chrome → osd → TX** so F12 menu stays on top.

`present_core.sv` is **not** the composite site for (c). It remains the **content** path only.

### F1.2 Pixel format

| Choice | Bits/px | Notes |
|--------|--------:|-------|
| **RGB565 + 1-bit key** (recommended v1) | 16 | Color-key (e.g. 0x0001) = transparent; matches ARM overlay habit of RGB565 (`playback_overlay.hpp`) |
| ARGB1555 | 16 | 1-bit alpha explicit |
| RGBA8888 | 32 | 2× DDR BW; reject for v1 |
| A8 + RGB565 dual plane | 24 | more BW/complexity |

v1: **little-endian RGB565**, transparent iff pixel == `CHROME_KEY` (parameter, default `16'h0001`). Opaque replace (no multi-bit blend) for minimal ALM/timing.

Later: 4-bit alpha ESTIMATE (+ALM for `(c*a+v*(15-a))>>4` per channel).

### F1.3 Alpha / blend model (v1)

```text
if (!chrome_de || chrome_px == CHROME_KEY)
  out = video_rgb;           // ascal path
else
  out = chrome_rgb565_to_888(chrome_px);
```

Pipeline: match `osd.v` style 1–2 cycle delay on HS/VS/DE with data (`osd.v` registers `rdout`).

### F1.4 How ARM delivers chrome

| Path | Verdict |
|------|---------|
| Full plane in **M10K BRAM** | **Fails** F2 — see arithmetic |
| **DDR region** (like F1) + thin on-chip line FIFO | **Required** for full-raster |
| SPI/ioctl tiny buffer | Only for glyph-cache v1 strip; not full HUD |
| Framework `osd.v` buffer | 256×64 class — wrong product |

**DDR layout (design):**

- Physical base: **new** window below content banks, e.g. after F1 doorbell region — exact phys **TBD** against `0x3000_0000` map + ascal `RAMBASE 0x2000_0000` (`sys_top.v:717`). Must not collide with ascal vbuf or F1 banks.
- Stride: `WIDTH * 2` bytes (RGB565), `WIDTH/HEIGHT` from live mode (mailbox or conf).
- Double-buffer 2 planes; swap on vsync (hdmi_vs) when ARM rings a new doorbell (reuse PLXK-style or dedicated PLXC chrome word).
- ARM: render overlay with `OverlayLayoutMetrics` using **output W×H** (not 624×480). Requires live mode discovery (ini / HDMI status) — gap noted in feasibility doc.

**Bandwidth implication (full plane, every frame):**

| Mode | Format | Bytes/frame | @60 Hz | Formula |
|------|--------|------------:|-------:|---------|
| 1920×1440 | RGB565 | 5 529 600 | **331.8 MB/s** | `1920*1440*2*60` |
| 1920×1080 | RGB565 | 4 147 200 | **248.8 MB/s** | derived |
| 1920×1440 | A8 only | 2 764 800 | **165.9 MB/s** | if separate colour ROM |

**DDRAM peak (same bus class as F1):** 64-bit × 90 MHz = **720 MB/s** peak if every cycle (`pll_0002.v` 90 MHz; bus width from `DDRAM_DOUT[63:0]`).  
331.8 / 720 ≈ **46%** of theoretical peak for chrome alone — **ESTIMATE** of load share; **real** available BW is less because:

- `ddr_frame_store` already reads content lines on `clk_ddr` during active video,
- ascal `vbuf` uses a **separate** 128-bit path @ `clk_100m` (`sys_top.v` ~640–649, `N_DW=128`) to `0x20000000`,

so chrome-on-`0x3000_0000` **contends with F1**, not with ascal vbuf. Contention risk is **F1 scanout + chrome scanout** on DDRAM port.

**Mitigations (design):**

1. Prefetch **N lines** during HBlank into M10K line FIFO (banded).
2. Dirty-rectangle: ARM writes only HUD band (bottom ~120 px) + RTL skip fetch outside `chrome_ymin..ymax` → BW scales with dirty height (e.g. 120/1440 → ~27.6 MB/s RGB565 @60) — **DERIVED** from full-plane formula × (120/1440).
3. Update chrome at 30 Hz or on UI events only; hold last plane (still need read BW every display frame unless on-chip cache holds dirty band).

---

## F2 — RAM cost (binding constraint)

Convention: `M10K_count = ceil(bytes * 8 / 10240)` = `ceil(bytes / 1280)`.

### F2.1 Full-raster BRAM — **FAILS**

| Buffer | Bytes | M10K | ≤88? |
|--------|------:|-----:|:----:|
| 1920×1440 RGB565 | 5 529 600 | **4320** | **NO** |
| 1920×1080 RGB565 | 4 147 200 | **3240** | **NO** |
| 1920×1440 A8 | 2 764 800 | **2160** | **NO** |
| 529×240 RGB565 (core DE plane) | 253 920 | **199** | **NO** |

**Finding (plain):** a full-output-raster chrome framebuffer **cannot** live in the remaining **88 M10K**. External DDR (or non-existence) is mandatory for full-plane (c).

### F2.2 Banded / scanline FIFO (DDR → N lines M10K)

Double-buffer N lines of RGB565 @ max width 1920 (mode 12):

| N (lines resident) | Bytes `N*1920*2` | M10K | ≤88? | Notes |
|-------------------:|-----------------:|-----:|:----:|-------|
| 1 | 3 840 | **3** | YES | tight prefetch |
| 2 | 7 680 | **6** | YES | ping-pong minimum |
| 4 | 15 360 | **12** | YES | comfortable |
| 8 | 30 720 | **24** | YES | matches product mental model of LINE_COUNT=8 |
| 16 | 61 440 | **48** | YES | half of free |
| 32 | 122 880 | **96** | **NO** | exceeds 88 |

**Recommendation:** **N=4 or N=8** RGB565 line FIFO (**12 or 24 M10K**), leaving **≥64 M10K** margin for decode work / fragmentation.

**DDR read BW (banded, continuous full-width):** still **must sustain average** `WIDTH*HEIGHT*2*fps` if every output pixel may be chrome-covered — banding does **not** reduce average BW; it only absorbs burstiness. BW reduction requires **sparse dirty geometry** or **1 bpp mask + glyph path**.

At 1920×1440@60 RGB565: **331.8 MB/s** average fill of the line FIFO from DDR (same as full plane).  
With dirty band height H_d only: `1920 * H_d * 2 * 60` B/s.

### F2.3 Sprite / glyph-cache compositor

**On-chip:**

| ROM | Bits | Bytes | M10K |
|-----|-----:|------:|-----:|
| 12×16 1bpp × 96 glyphs | 18 432 | 2 304 | **2** |
| 12×16 1bpp × 256 glyphs | 49 152 | 6 144 | **5** |
| 24×32 1bpp × 96 (output-native-ish) | 73 728 | 9 216 | **8** |
| 16×24 1bpp × 96 | 36 864 | 4 608 | **4** |

**ALM cost of address/blend logic:** **ESTIMATE 400–1 500 ALMs** for a text+bar engine (glyph fetch, cursor, fill rects) — **no map in-repo for this block**; treat as ESTIMATE until quartus map. Compare: framework `osd.v` is small but menu-only; player HUD needs more draw list state.

**Draw-list in regs:** ~16 commands × ~16 B = 256 B → **0 M10K** (registers) or 1 M10K if stored in RAM.

| Glyph-cache shape | M10K | Fits 88? | Meets full HUD? |
|-------------------|-----:|:--------:|-----------------|
| Font ROM 12×16@256 + tiny cmd RAM | ~5–6 | **YES** | Partial (text/icons); complex shapes harder |
| Font ROM 24×32@96 + cmd | ~8–10 | **YES** | Better output-native text |
| Glyph + 8-line RGB565 scratch | ~8+24=32 | **YES** | Hybrid |

**Finding:** glyph-cache **fits** M10K easily; full-plane BRAM **does not**. Banded DDR **fits** M10K. **None** of the full-raster BRAM options fit.

### F2.4 Which fits? (summary)

| Approach | M10K | Fits 88? | User-sharp at 1920×1440? |
|----------|-----:|:--------:|--------------------------|
| Full-raster BRAM | 2000–4320 | **NO** | yes if it fitted (it doesn't) |
| Banded DDR N=2..16 | 6–48 | **YES** (N≤16) | **yes** if ARM paints at output res |
| Glyph-cache BRAM | 2–10 | **YES** | **yes** for text/icons; limited art |
| Hybrid glyph + N=4 scratch | ~20 | **YES** | best v1 flexibility |

---

## F3 — Interaction with `V_STORE=240`

Quoted:

```systemverilog
// present_core.sv:161-164
localparam H_DE    = 10'd529;
localparam V_STORE = 10'd240;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;  // FRAME_H=480 → 2.0 exactly
```

With `FRAME_H=480`, `STORE_Y_SCALE = 2.0` exactly → `store_y` steps **0,2,4,…,478** (odd content rows never fetched). Also `past_last_row = (py >= 240)` blanks surplus row (`present_core.sv` ~194–195).

### Does (c) bypass this?

| Path | Subject to V_STORE? |
|------|---------------------|
| Content video (F1 → `ddr_frame_store` → `store_y`) | **YES** — unchanged |
| Chrome composited **after ascal** | **NO** — never enters `present_core` store addressing |
| Chrome if mistakenly painted into F1 bank | **YES** — still culled / soft |

**(c) genuinely solves the user complaint for chrome** because chrome pixels are generated/fetched in the **HDMI raster**, not looked up through `store_y`.  
It does **not** give content video true 480-line vertical resolution; that remains a separate `V_STORE`/fetch problem. User ask was about **overlays/text**, not film grain.

---

## F4 — Risk register and smallest testable increment

### Fail modes (fit / silicon)

| # | Risk | Why it kills a fit | Detection |
|---|------|--------------------|-----------|
| R1 | **M10K overrun** | N too large, dual plane, or accidental full buffer infer | map RAM >553 or free &lt;0 vs baseline 465 |
| R2 | **DDRAM contention** | Chrome + F1 underruns → tear/freeze | existing freeze TB + underrun counters; HDMI motion |
| R3 | **clk_hdmi timing** | Blend adds logic on HDMI pixel path | post-fit STA on HDMI domain; negative slack HARD_FAIL |
| R4 | **Pipeline misalign** | Chrome shifted vs video (like DE_LAG class) | edge markers on chrome rect |
| R5 | **Mode mismatch** | ARM paints 1080, HDMI 1440 | mailbox mode vs ini |
| R6 | **ascal/osd interaction** | Wrong mux order blanks chrome or menu | F12 menu + PAUSED both visible |
| R7 | **Touching working scanout** | Regress `c5382bee` path | freeze TB RED/GREEN; parent pixel tests |

### Timing risk

- Composite is on **`clk_hdmi`** (ascal output domain), not `clk_sys` 20 MHz.
- Keep blend to **1 LUT tier + 1 register** (key mux), mirror `osd.v` multi-stage register.
- Do **not** put DDR read response combo into HDMI DE without a line FIFO (R2/R3).

### Smallest testable increment (one future fit)

**Inc-1 (prove tap only):**

1. No ARM DDR chrome yet.
2. RTL: on `clk_hdmi`, after shadowmask, force a **hardware rectangle** (fixed x0,y0,x1,y1 in output pixels) with solid colour when `chrome_enable` strap/mailbox=1.
3. BRAM: **0** new M10K. ALM: **ESTIMATE &lt;200**.
4. Pass criterion (parent pixels): rectangle edges **1 px sharp** at 1920×1440 (not 3 px mush); content video unchanged; freeze TB still GREEN.
5. **Does not** ship player UI — only proves post-ascal tap + no scanout regression.

**Inc-2:** N=4 line FIFO + DDR dirty band for bottom HUD; ARM paints PAUSED at output W×H.  
**Inc-3:** glyph-cache optional to cut BW.

Do **not** combine Inc-1 with thruput RMW / −32 DSP / 907e on first chrome fit unless map headroom proven — chrome risk is HDMI-domain + DDRAM, orthogonal failure class to dequant DSP.

### Pre-register (for when slot opens) — ESTIMATE where noted

| Resource | Inc-1 HW rect | Inc-2 N=4 DDR band |
|----------|--------------:|-------------------:|
| ALM Δ | +50..200 ESTIMATE | +500..2000 ESTIMATE |
| DSP Δ | 0 | 0 |
| RAM Δ | **0** | **+12 M10K** (derived table) |
| setup/hold | must stay ≥0 on HDMI + sys | same + DDR path |

Baseline RAM 465 + 12 = **477/553** if no other growth — **derived**; confirm on map.

---

## F5 — Stale integration branches

| Branch | Tip (this machine) | Date | Role for (c) |
|--------|--------------------|------|----------------|
| `integ/fit4-prep` | `6bdc7452` | 2026-07-29 | **Retire** as base — pre-`c5382bee` working DDR era |
| `integ/fit5-prep` | `86ebf5ce` | 2026-07-29 | **Retire** as base |
| `integ/rtl-consol` | `cef8c0c4` | 2026-07-29 | **Retire** as base — map ALM experiments, not chrome |
| `w-fit-integ-c5382bee-dequant-swap` | current | 2026-07-31+ | **Keep** as fit-ready bag (dequant/907e/thruput) — **not** chrome design host unless rebased onto **product tip that ships `c5382bee`** |
| `w-osd-hires` | feasibility `1c531e3f` | 2026-08-01 | **Requirements + ARM chrome authoring** — continue software metrics; RTL (c) is new modules near `sys_top` |

**Base for implementation when granted:** **minimal delta from the exact sources that built working `c5382bee`**, plus new `plex_chrome` + thin DDR port.  
**Do not** open fit4/fit5/rtl-consol and hope. Cherry-pick only with evidence.

---

## Decision summary for parent

1. **(c) is correct** and must composite **after ascal on `clk_hdmi`**, not in `present_core`.
2. **Full BRAM plane: impossible** in 88 M10K (4320 needed for 1920×1440 RGB565).
3. **Fits:** banded DDR N≤16 (prefer 4–8) and/or glyph-cache (2–10 M10K).
4. **`V_STORE=240` is bypassed for chrome** under (c); content video still capped.
5. **Smallest fit:** Inc-1 hardware rectangle post-ascal (0 M10K) to prove tap without betting the slot on full HUD.
6. **Slot stays closed** until parent grants; this document is not a fit request.
7. **Stale July-29 integ branches: retire as bases.**

---

## Parent verification commands (device — parent only)

```bash
# Confirm output mode still 12 / 1920x1440
grep -E 'video_mode' /media/fat/MiSTer.ini; echo "true rc=$?"

# After any future Inc-1 RBF only: capture and measure rectangle edge width in px
# (expect ~1.0 px solid edge, not ~3 px soft) — parent scoring tool
```

## Labels legend

- **Quoted:** file:line or parent measurement.  
- **Derived:** arithmetic from quoted constants.  
- **ESTIMATE:** not from a map/fit report — must be replaced by map numbers before trusting a fit grant beyond Inc-1 intent.
