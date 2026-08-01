# OSD / playback chrome sharpness (w-osd-hires)

Status: **silicon-verified** on stop path (`7defbdf6` / md5 `db3d9367`); read-back gate
validated on a **real HDMI pair**.  
Related: `host/libmisterplex/playback_overlay.hpp`, `arm/misterplexd/media_player.cpp`,
`fpga/Plex_MiSTer/rtl/present_core.sv`, `tools/readback_overlay_text.py`,
`docs/display-resolution.md`.

## Output resolution: gap vs ceiling (settled)

Split two questions that were conflated:

### A) Can ARM *know* HDMI `video_mode` WxH?

**Gap (not a hard ceiling).** Product `misterplexd` does **not currently read** it
(only a comment mentions `video_mode` in `media_player.cpp`). It is still
**readable on-device** without RTL:

| Source | Evidence | Used for overlay today? |
|---|---|---|
| `/media/fat/MiSTer.ini` `[Plex] video_mode=` | Same FS daemon already uses (`main.cpp` conf under `/media/fat/misterplex/`); `scripts/sweep_plex_video_modes.sh` edits this file | **No** |
| `/dev/fb0` `FBIOGET_VSCREENINFO` xres/yres | `fb_present.cpp:27-37` | **No** — and product path is `PRESENT=fpga` DDR, not fb0 sizing |
| Live scaler WxH via HPS | Framework `sys_top.v` holds `WIDTH` / `hdmi_width` for ascal; not wired into misterplexd SPI status today | **No** |

So “daemon has no video_mode read” = **implementation gap**. Knowing WxH still does
**not** let ARM paint a 1920×1440 buffer into the product F1 path (see B).

### B) Can ARM *composite* chrome at HDMI output resolution on the product path?

**Ceiling (RTL/fit).** Overlay pixels only reach HDMI through:

| Layer | Geometry | Source |
|---|---|---|
| Overlay authoring | coded bank **624×480** | `plex480pDdrFrameGeometry()` / `ddrGeometry.coded_*` |
| Present fetch | **240 unique Y samples**, even bank rows only | below |
| HDMI out | `video_mode` (e.g. 12 → 1920×1440) | `ascal` in `sys_top.v` after present_core |

**Vertical ceiling quantified** (`Plex.qsf` `FRAME_H=480`, `present_core.sv:161-200`):

```text
STORE_Y_SCALE = (FRAME_H * 65536) / 240 = 131072 = exactly 2.0 in 16.16
store_y = (py * STORE_Y_SCALE) >> 16  for py in 0..239
        = 0, 2, 4, …, 478
```

- Unique `store_y` values: **240**. Odd bank rows **never** fetched (`parity={0}`).
- Effective vertical resolution of anything in the bank (video **or** overlay) before
  ascal is **240 lines**, not 480 — half the authored rows are discarded, not blended.
- Horizontal DE is `H_DE=529` with a separate X scale into `FRAME_W`.

### C) Does `vscale≥2 + even-y` fix (B)?

**Accommodates, does not restore resolution.**

| | scale=1 (old) | scale≥2 + even y (this branch) |
|---|---|---|
| Glyph row → content rows | 1 row | ≥2 rows |
| After even-row fetch | **Alternate glyph rows deleted** → wrong characters (`8→0`) | Each glyph row keeps ≥1 survivor |
| Distinct vertical samples to ascal | still ≤240 | still ≤240 |

So the fix stops **character corruption** and makes STOPPED/timecodes human-legible
inside the 240-line ceiling. It does **not** give 480 independent chrome lines or
native `video_mode` sharpness. Restoring full vertical detail needs RTL
(`V_STORE`/`STORE_Y_SCALE`, separate OSD plane, or post-ascal composite).

ARM-only max on this path: full **bank** chrome (not decode 320×240), phase-safe
glyphs, pause/play paint. Host pin:
`tests/unit/test_overlay_raster_geometry_static.py`.

## Mechanism (settled)

`present_core.sv` fetches only **even** store rows (`STORE_Y_SCALE=2.0` with
`FRAME_H=480`). Glyphs drawn at vertical scale=1 lose alternate rows → character
corruption (`8→0`, `6→C`). Fix: **bodyScale/iconScale ≥ 2** and **even y-origin snap**.

## Paths (quoted)

| Event | Code | Format |
|---|---|---|
| Stop / idle chrome | `paintIdle()` → `overlay_.renderRgb24` @ coded W×H → RGB→I420 → DDR | RGB intermediate |
| Playback present | `renderOverlay` → `case Yuv420p: overlay_.renderYuv420p(...)` | direct YUV |
| Pause | `pause()` → `showPlaybackOverlay(Paused)` → **`publishPausedOverlayFrame()`** before `SIGSTOP` | YUV latch + `renderYuv420p` |

Pause/play paint is **in tree** (`media_player.cpp` `publishPausedOverlayFrame`,
`renderOverlay` Yuv420p branch). Parent stop-path capture proves stop; **pause/play
on silicon is still parent-only** — agent has not device-tested those two.

## Acceptance — string read-back (two-sided)

Gate specification fixtures (same device + grabber; differ only by the fix):

| Fixture | Expect |
|---|---|
| `tests/unit/fixtures/overlay_readback/overlay_lowres_evidence.png` | **RED** — must NOT recover `STOPPED` |
| `tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png` | **GREEN** — must recover `STOPPED` |

```bash
python3 tools/readback_overlay_text.py --selftest-pair; echo "true rc=$?"
python3 tools/readback_overlay_text.py --image CAPTURE.png --expect STOPPED; echo "true rc=$?"
```

- Templates = shipped **8×13 / 12×16 @ scale≥2** (not legacy 5×7@1).
- HDMI 1080p is area-downsampled to a 640×480 content proxy before match.
- Unsupported geometry → `verdict=UNSCORED` **rc=77** (never collapsed into FAIL).
- Synthetic green alone is **not** the gate; the pair is.

## Multi-resolution output (parent switch procedure)

Output mode is **MiSTer.ini `[Plex]`**, not misterplex.conf. See
`docs/display-resolution.md`.

```sh
# on device (parent only)
cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.before-osd-hires-sweep
vi /media/fat/MiSTer.ini   # set video_mode / _ntsc / _pal in [Plex]
# recommended tiers:
#   video_mode=8  → 1920×1080@60  (already GREEN on FIXED capture)
#   video_mode=5  → 800×600@60
#   video_mode=6  → 640×480@60
# 240p-class: use a 240p modeline the lab already trusts, or vscale path that
# yields ~240 active lines — confirm with grabber actual WxH before scoring.
reboot
# after core up: cast → stop → capture HDMI → readback
python3 tools/readback_overlay_text.py --image CAP.png --expect STOPPED; echo "true rc=$?"
```

### Pre-registered predictions (publish hits/misses)

Chrome is authored on the **coded canvas** (product 624×480), not HDMI pixels.
ascal scales DE ~529×240 → whatever `video_mode` is. Odd-row cull is **unchanged**
across output modes (it is in `present_core` before ascal).

| Output (`video_mode`) | Signal | Prediction for STOPPED read-back | Notes |
|---|---|---|---|
| 8 — 1080p60 | 1920×1080 | **PASS** (measured GREEN on FIXED) | baseline |
| 5 — 800×600 | 800×600 | **PASS** | same content glyphs; more ascal shrink; separation still high enough |
| 6 — 640×480 | 640×480 | **PASS** | near 1:1 with presented bank; should be easiest after 1080p |
| 240p-class | ~320×240 / 640×240 | **PASS or tight** | layout picks 8×13 @ scale≥2; if grabber geometry is exotic → **UNSCORED 77**, not FAIL |
| Pause overlay | any | **PASS** (code path present; **untested on silicon**) | `publishPausedOverlayFrame` |
| Play overlay while playing | any | **PASS** when overlay visible (3s) (code path present; **untested on silicon**) | `renderYuv420p` each dirty present |

Miss condition to publish: any tier where human can read STOPPED but tool returns
FAIL, or tool PASS on unreadable mush.

## Out of scope

`V_STORE` / Quartus. Only if multi-res read-back stays RED on silicon with
human-legible chrome.

## Even-row cull gate (host, no device)

```bash
python3 tools/even_row_cull_glyph_gate.py; echo "true rc=$?"
```

| Arm | Result |
|---|---|
| RED | 5×7 @ scale=1 → after even-row keep: mid-bar of `8` **dead**; 3/7 glyph rows culled |
| GREEN | 12×16 @ scale=2 even y → STOPPED template frac ≥ 0.90 after same cull |

`PAIR_OK` proves the fix is **not** a canvas-size no-op under the real fetch rule, and that
scale≥2 **accommodates** the 240-line ceiling without restoring 480 independent lines.
