# Player chrome vs MiSTer output raster — feasibility (no fit)

**Status:** architectural finding. Font/path work on `w-osd-hires` is **not** the
user's remaining bug. No RTL fit requested or started.

**User requirement (verbatim intent):** overlays must match the **MiSTer output
resolution**, not the streaming/content geometry, and scale with modes such as
800×600, 640×480, and 240p.

---

## A1 — What resolution is actually in play?

### Measured (this tree / archives)

| Fact | Evidence |
|---|---|
| Grabber PNGs are **1920×1080** | `load_png_luma` on `files/device-evidence/osd_pause_3883f5ab_PAUSED_PASS.png`, `osd_hires_0370af91_STOPPED_PASS.png`, `overlay_FIXED_db3d9367_stopped.png` → `1920x1080` |
| Product DDR bank is **624×480** coded | `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh`: `DDR_FRAME_CODED_WIDTH=624`, `DDR_FRAME_CODED_HEIGHT=480`; ARM `plex480pDdrFrameGeometry()` |
| Chrome is authored into that bank | `publishPausedOverlayFrame` / `paintIdle` → `renderYuv420p` / `renderRgb24` at `cw×ch` from `plex480pDdrFrameGeometry()` |
| PAUSED glyphs are **12×16@2** on silicon | Parent independent advance mean **77.4 px** vs pred `13*2*(1920/624)=80.0` (err 3.3%); worker left-label span **~441–452** @1920; vertical D ink **54 px** vs `12*2*(1080/480)=54` |
| Present path unique V samples ≤ **240** | `present_core.sv:161-164`: `V_STORE=240`, `STORE_Y_SCALE=(FRAME_H*65536)/240` with `FRAME_H=480` → **exactly 2.0** → even store rows only |

### Documented mode table (not a live device read by this worker)

| `video_mode` | Output signal | Source |
|---:|---|---|
| 8 | 1920×1080@60 | `docs/display-resolution.md`, `docs/crt-lcd-matrix.md` |
| 12 | 1920×1440@60 | same |
| 5 / 6 | 800×600 / 640×480 | same |

### Not measured by this worker (parent must quote)

- Live `[Plex] video_mode=` on the daily-driver box.
- Whether HDMI before the grabber is 1080 or 1440.

**Parent command (device, parent only):**

```bash
ssh root@192.168.1.183 'grep -E "^(video_mode|video_mode_ntsc|video_mode_pal)=" /media/fat/MiSTer.ini | head -20; sed -n "/^\[Plex\]/,/^\[/p" /media/fat/MiSTer.ini | grep -E "video_mode"'
# true rc=$?
```

### Scale arithmetic — what 2.25 does and does not prove

Grabber archive height / bank height:

```text
1080 / 480 = 2.25
```

That ratio is **consistent with**:

1. HDMI `video_mode=8` (1920×1080) and grabber 1:1 with HDMI, **or**
2. HDMI `video_mode=12` (1920×1440) and grabber vertical squash `1080/1440=0.75`, net still `1440/480 * 0.75 = 2.25`.

So parent’s vertical glyph math **does not uniquely identify** mode 8 vs 12. Horizontal
`1920/624 ≈ 3.077` is shared by both (same active width). **Only the ini/EDID read
settles live HDMI.** For the architecture claim below, both cases share the same
defect: chrome is **not** painted at HDMI WxH.

---

## A2 — Options (constraints attached)

Hard constraints (quoted / parent baseline):

```systemverilog
// present_core.sv:161-164
localparam H_DE    = 10'd529;
localparam V_STORE = 10'd240;
localparam int STORE_Y_SCALE = (FRAME_H * 65536) / 240;  // FRAME_H=480 → 2.0 exactly
```

- FPGA area baseline (parent): **ALM 21,095/41,910 · DSP 74/112 · RAM 465/553**
  → **88 M10K free (~112 KiB)**. Binding resource for on-chip framebuffers.
- Product DDR bank is external DDRAM (not the 88 free M10Ks), but **any new on-chip
  line buffer / OSD BRAM** still competes for those 88 blocks.
- No exclusive Quartus slot for chrome (parent: three failed fits this session).

Rough on-chip buffer sizes (bytes → ~M10K @ 1280 B/block; **must fit ≤88** if BRAM):

| Buffer | Bytes | ~M10K | Fits 88? |
|---|---:|---:|---|
| 529×240 RGB565 (DE plane) | 253 920 | ~198 | **No** |
| 960×540 A8 | 518 400 | ~405 | **No** |
| 1920×1080 RGB565 | 4 147 200 | ~3240 | **No** |
| 1920×1440 RGB565 | 5 529 600 | ~4320 | **No** |

### (a) Software-only: raise `bodyScale` to 3 at `h≥480`

| | |
|---|---|
| **What changes** | `playback_overlay.hpp` `OverlayLayoutMetrics::compute`: today `bodyScale = h>=720 ? 3 : 2`. Product bank is always h=480 → scale stays 2. Force scale 3 (and keep even-y). |
| **Cost** | ARM-only; no RBF; deploy with existing black-rect binary. |
| **User terms** | Makes icons/text **larger** on the stretched panel. **Does not** make them **sharper** at output. Still authored at 624×480 (effective ≤240 V samples after present), still upscaled by ascal. **Does not satisfy** “match the MiSTer output resolution”. |
| **Even-row** | scale≥2 already survives cull; scale=3 also survives. |
| **RBF?** | No |

### (b) Larger DDR overlay / coded canvas

| | |
|---|---|
| **What changes** | Raise `DDR_FRAME_CODED_*` / presented size; ARM pack + overlay author at new WxH; `present_core` `FRAME_W/H`, `STORE_*_SCALE`, doorbell layout. |
| **Cost** | **New RBF required** (params + present are synthesis-fixed). DDR bandwidth and fit risk; video decode path also bound to this bank today. |
| **Sharpness** | If `V_STORE` stays 240 and scale still drops odd/fractional rows, **vertical chrome detail still collapses** to ~240 unique samples before ascal — larger bank alone does **not** equal output-sharp chrome. Need `V_STORE`/fetch to cover full authored height **and** ascal not to be the first place chrome meets HDMI. |
| **RAM 88** | Extra **on-chip** line buffers for a taller/wider present path may not fit; external DDR capacity is a different budget (not the 88 M10K). |
| **RBF?** | **Yes** |

### (c) Separate high-res chrome plane at output raster (RTL)

| | |
|---|---|
| **What changes** | Composite player chrome **after** content scale (post-`present_core` / post-`ascal`, or parallel blender at HDMI timing). ARM writes an overlay buffer sized to **live `video_mode` WxH** (or a fixed max mode with letterbox). Layout metrics = f(output W,H). |
| **Cost** | **New RBF**; SPI/DDR path for overlay; blender mux; ARM must learn live mode (ini/`fb0`/status — gap today, see `docs/osd-hires.md` §A). |
| **User terms** | **This is the only option that matches the user’s words:** chrome pixels authored at output resolution (or 1:1 with HDMI active), independent of DECODE/DDR content bank. At 800×600/640×480/240p, layout scales **down** from the same model. |
| **RAM 88** | Full 1080p RGB565 plane **does not fit** in 88 M10K (~3240 blocks). Viable shapes need **external DDR** for the overlay buffer (like F1), with **small** on-chip line FIFOs only — design must keep BRAM ≤ free budget. Framework `sys/osd.v` is a tiny F12 menu buffer, not a full-raster player plane. |
| **RBF?** | **Yes** |

---

## A3 — Recommendation (user terms)

**True fix = (c): output-raster chrome plane, new RBF.**  
Software cannot composite “at MiSTer output resolution” on the current F1 path because
every ARM pixel is written into the **624×480 content bank** and then stretched by
`present_core`+`ascal`. That is exactly “bound to streaming/content geometry.”

| Ship now? | What | Honest label for user |
|---|---|---|
| **Yes (ARM)** | Black-rectangle fix already in tree (`panelBg` opaque + title) | Real defect; legibility of empty panel |
| **Optional cosmetic** | (a) bodyScale=3 | **Bigger** mush, not sharp HDMI chrome — **do not call the bug fixed** |
| **Later exclusive** | (c) with DDR-backed overlay + thin BRAM FIFOs; pre-register ALM/DSP/RAM | Matches requirement; needs free fit slot + RAM plan |

**Do not ship (a) as the resolution fix.** Prefer telling the user: *player controls
are already the max font on the content canvas; looking soft at 1080/1440 is structural
until chrome is drawn after the scaler.*

**Interim product honesty:** sticky PAUSED/STOPPED + scale≥2 + 12×16 made chrome
*legible* under the 240-line ceiling. That is a different claim from *output-native*.

---

## A4 — Black rectangle (software, deploy)

Still in `host/libmisterplex/playback_overlay.hpp` (`panelBg{42,46,54}` opaque, title
band). Commit ancestry includes `8475a8dd`. Deploy candidate ARM md5
`14b00f600aa62ac0948e24273e7030a1` (`4ed6a096` tip at write-up).

**Parent score P1 only for this ship:** empty-centre mean luma **50–70** grey (not ≤35
black hole), after pause ≥6 s sticky. Not a substitute for (c).

---

## Parent checks (no agent device access)

```bash
# Live mode (settles A1 HDMI)
grep -E 'video_mode' /media/fat/MiSTer.ini

# Black-rect deploy
# md5 live misterplexd == 14b00f600aa62ac0948e24273e7030a1
# pause 6s → capture → empty-centre luma in panel mid band

# Do NOT expect font span to jump to native-1080 sharpness without RTL (c)
```
