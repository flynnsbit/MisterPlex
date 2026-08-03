# Architectural fork: ascal-native 960×540 @ ≤20 MHz vs clk_pix 29.7 / PPC path

**Question (rd-duck):** sys_top ascal already takes arbitrary core `CLK_VIDEO`/DE and
outputs HPS-configured 1280×720@60. Could a **scalar 960×540** core raster at
**≤20 MHz / ~24 Hz** (e.g. totals ~1100×758) let stock ascal do 960→720 upscale,
and skip new 29.7 CDC / 2-PPC / custom tap plumbing for a **near-term fit**?

**w-clock answer for parent:** **No source-backed hard forbid.** The simpler path is
architecturally legal on this tree. clk_pix/PPC work stays **upgrade/fallback**, not
the only way to put 540p banks on 720p HDMI.

Fit grant policy is parent's; this doc is evidence only.

---

## 1) What the framework actually does (quoted)

### Core → ascal **input** (not HDMI)

`sys_top.v` emu ports:

```verilog
.CLK_VIDEO(clk_vid),
.CE_PIXEL(ce_pix),
// …
assign clk_ihdmi = clk_vid;
assign ce_hpix   = vga_ce_sl;   // CE after scanlines
// …
.i_clk (clk_ihdmi),
.i_ce  (ce_hpix),
.i_de  (hde_emu),
// …
.o_clk (clk_hdmi),   // hdmi_clk_out — separate
.hdisp (WIDTH),      // from HPS video_mode
.vdisp (HEIGHT),
.iauto (1),          // measure input from DE
```

So: **HDMI timing = HPS `video_mode` (e.g. 720p60).**  
**Core timing = content delivery into ascal.** They are not required to match.

`Plex.sv` (macros off — shipping):

```verilog
assign CLK_VIDEO = clk_sys;   // 20 MHz
assign CE_PIXEL  = ce_pix;    // product often 1
```

With `PRESENT_CLK_PIX_PLL`: `CLK_VIDEO = clk_pix` @ 29.7 — **optional upgrade**.

### ascal capacity (source)

`ascal.vhd` defaults used by sys_top: `IHRES` power-of-two max (default **2048**),
`OHRES` ∈ {1024,2048,2304,…} default **2304**, `RAMSIZE` 8 MB (or 2 MB small).

| Need | Limit | 960×540 / 1280×720 |
|------|------:|--------------------|
| Input width | IHRES ≥ 960 | **OK** (2048) |
| Output width | OHRES ≥ 1280 | **OK** (2304) |
| FB bytes ~960×540×3×buffers | ≪ 8 MB | **OK** |

**No quoted assert** in-tree that rejects 960×540 progressive RGB into ascal.

---

## 2) Pixel-rate arithmetic (why 20 MHz works for **source** geometry)

**Active content @24:**  
`960 × 540 × 24 = 12.4416 Mpix/s` ≪ 20 Mpix/s.

**Example totals (rd-duck ~1100×758):**  
`1100 × 758 = 833_800`  
`F = 20e6 / 833_800 ≈ 23.99 Hz` at CE=1 — **same-clock feasible**.

**Contrast — glass CEA 1650×750 on core:**  
`20e6 / 1_237_500 ≈ 16.16 Hz` — that is why **1280-wide core CEA** needs 29.7 for ~24 Hz **into ascal**.  
If the core DE is **960×540**, that 16 Hz wall **does not apply**.

| Core DE | Totals class | clk @ ~24 Hz content | Needs clk_pix 29.7? |
|---------|--------------|----------------------:|---------------------|
| 1280×720 CEA | 1650×750 | 29.7 MHz | **Yes** (current upgrade path) |
| 960×540 | e.g. 1100×758 | **≤20 MHz** | **No** |

---

## 3) Is anything source-backed **forbidding** the simpler path?

| Candidate forbid | Verdict | Evidence |
|------------------|---------|----------|
| ascal requires core = HDMI size | **False** | `i_*` vs `o_*` separate clocks; `iauto` |
| ascal cannot upscale 960→1280 | **False** | polyphase scaler; IHRES/OHRES OK |
| CE_PIXEL must be 74.25 for 720p HDMI | **False** | HDMI from `hdmi_clk_out`; core CE is input |
| Bank/ABI forces 1280 glass beam | **False for simpler path** | Banks are **960×540 / 777600 B**; identity map works if **beam = FRAME** |
| Multi-pixel / clk_pix already shipped ON | **False** | macros **default OFF** |
| VIDEO_AR 4:3 hard-breaks 16:9 | **Config risk, not architecture forbid** | `Plex.sv` default `VIDEO_ARX/Y = 4/3` when `!ar` — **16:9 content should set AR 16:9** so ascal window is correct |
| Direct-video bypass | N/A if product uses HDMI+ascal | `direct_video` path exists; lab uses scaler path |
| 24→60 judder / lowlat triple-buffer | **Unknown quality** | needs parent glass; not a compile-time forbid |
| Custom w-scaler exact 4/3 phase | **Product quality choice** | ascal poly ≠ frozen exact-4/3 taps; different picture, not illegal |

**Conclusion:** There is **no** cited RTL/framework constraint that makes ascal-native 960×540 @ 20 MHz **illegal**.  
What remains is **product choice** (quality, cadence, chrome alignment) + **measure**.

---

## 4) What the simpler near-term fit would actually be

**Macros OFF** (already shipping defaults):

1. `present` beam / timing = **960×540 DE** (not 1280×720 glass).  
2. Totals chosen so `clk_sys × CE / (Htot×Vtot) ≈ content_fps` (24 → ~20 MHz OK).  
3. Store map **identity** (FRAME == beam) — avoids glass≠source smear class.  
4. `CLK_VIDEO = clk_sys`, `CE_PIXEL = 1` (or existing ce).  
5. HPS `video_mode = 720p60`; ascal scales + frame-rate-converts to 60.  
6. Set **AR 16:9** for 960×540.  
7. **Do not enable** `PRESENT_MULTI_PIXEL` / `PRESENT_CLK_PIX_PLL` for this fit.

**Eliminates for this fit:** outclk_3, async npx CDC, PPC unpack, Bresenham lead, custom glass→store 4/3 in present (ascal owns scale).

**Does not eliminate:** correct bank capacity (w-mem Option-C), ARM publish 960×540, daemon path, ascal picture quality acceptance.

---

## 5) When clk_pix / PPC remains the right upgrade

Keep staged work as **upgrade/fallback** when parent wants:

| Goal | Simpler ascal-native | clk_pix + PPC path |
|------|----------------------|--------------------|
| 540p banks on 720 HDMI soon | **Best near-term** | Overkill if ascal OK |
| Core-side exact 4/3 / frozen taps | ascal poly only | w-scaler + 1280 beam |
| Core content rate = glass CEA 24/30/60 | ascal FRC masks | **Needs 29.7 / 37.125 / 74.25** |
| Bypass ascal / direct_video 720 | N/A | Must self-time 720 |
| Prove fabric scanout headroom | — | STA + npx long-haul |

**STA note:** ascal-native fit still needs **clk_sys Fmax ≥ 20** with whatever present/beam is enabled — but **not** Fmax(clk_pix)≥29.7 or wide-FIFO pix cone.

---

## 6) Honest risks (not forbids) — pre-register for parent glass

1. **ascal 24→60:** unique frames 24 Hz; motion is film cadence (OK for film; TV 30 still ARM problem).  
2. **Scaler look:** ascal poly vs w-scaler exact-4/3 — may look “softer” or different phase; A/B capture.  
3. **AR mis-set →** pillar/letter wrong — fix AR, not clocks.  
4. **If someone leaves beam at 1280×720 @ 20 MHz** thinking “ascal will save refresh” — content into ascal is still **~16 Hz**; picture updates slow. Simpler path **requires 960 DE**.  
5. **Chrome/OSD** are post-ascal @ HDMI res — OK; do not assume core-pixel chrome.

---

## 7) Recommendation to parent

| Priority | Action |
|----------|--------|
| **Near-term fit (unblock glass)** | Prefer **ascal-native 960×540 @ ≤20 MHz**, macros OFF, identity store, AR 16:9, `video_mode` 720p60. Smallest delta; no new CDC. |
| **Hold** | clk_pix 29.7 + PPC + ordered tag + wide FIFO as **staged upgrade** when core must emit 1280 glass or bypass ascal — already default-OFF and TB'd. |
| **Do not** | Claim either path “720p60 content” without measuring unique frame rate into ascal / on glass. |
| **Measure** | Parent: idle/playback capture + whether ascal fill looks acceptable vs custom 4/3. |

**One line:** Nothing in sys_top/ascal/Plex **forbids** the simpler path; the 29.7 stack was solving **1280-wide core CEA @24**, which is optional if ascal upscales **960** core DE.
