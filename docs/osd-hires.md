# OSD / playback chrome sharpness (w-osd-hires)

Status: **silicon-verified** on stop path (`7defbdf6` / md5 `db3d9367`); read-back gate
validated on a **real HDMI pair**.  
Related: `host/libmisterplex/playback_overlay.hpp`, `arm/misterplexd/media_player.cpp`,
`fpga/Plex_MiSTer/rtl/present_core.sv`, `tools/readback_overlay_text.py`,
`docs/display-resolution.md`.


## ERROR-18 retract (parent 2026-08-01) + source stroke falsifier

Parent retracted the claim that a uniform 1px stroke non-integer-upscaled to ~1.89×
produces display bins `{7,8,9,10}`. **Impossible by construction** for `fillRect` block
fonts: source runs are integer multiples of `bodyScale`.

Zero-device gate: `tests/unit/test_overlay_source_stroke_hist.cpp`

| Claim | Evidence on tip |
|---|---|
| Glyph is 5×7 (`row<7`,`col<5`) | **STALE** — tip has 8×13 / 12×16 / **24×32**; no 5×7 loop |
| `font=12x16` label lie | Was true for prior tip; product bank now logs **`font=24x32 cell=48x64`** |
| Source multi-width 7–10 | **FAIL** — LABEL hist multiples of scale only; odd runs = 0 |
| Display multi-bin | Stretch + bar/icons; NN 2.25× of even source → e.g. bin 9 from width 4 |

**Product font (plane=0 bank):** `OverlayFontId::Hires24x32` stroke-raster (not NN of
12×16) @ `bodyScale=2` → `textCellH=64` → ~32 unique store rows after even-row cull
(vs 16 for 12×16@2). Still capped by 240-line present ceiling + ascal; fabric plane
remains required for true output-native chrome.

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

## Readback font metadata (measured, not template-winner)

`tools/readback_overlay_text.py` recovers the string by template score, but
**reports `font`/`scale` from measured ink span** vs cell-span predictions
(`(n-1)*advance*sc + glyphW*sc`). If 8×13 vs 12×16 is ambiguous → `font=UNRESOLVED`
(never a confident wrong pick).

```bash
python3 tools/readback_overlay_text.py --selftest-font-measure; echo "true rc=$?"
# paints 12x16@2 and 8x13@2 for STOPPED/PAUSED — each must report matching font
```

Parent falsifier: template-only metadata had PAUSED=8×13 and STOPPED=12×16 swapped.
FIXED silicon fixture under measured font: **12×16@2** `measured_span=173` (pred 180).

## STOP/idle authoring canvas

**Source (current):** `MediaPlayer::paintIdle` uses `plex480pDdrFrameGeometry()` →
`cw×ch = 624×480`, then `overlay_.renderRgb24(rgb, cw, ch)`. Font pick:
`h >= 480 && bodyScale == 2` → **12×16** (no `w>=600` — that clause was dead on the
product path and would mask a short-H canvas). Host ink span STOPPED@624×480 = 174
(pred 180). Loud log: `media: idle overlay canvas=624x480 font=12x16 scale=2 chrome=0|1`.

**Stopped is sticky** in `alphaFor` (same as Paused) so late captures still see STOPPED.

### R1 — parent 370 vs host FIXED span (settled for on-disk archive)

| Artifact | Status |
|---|---|
| `osd_hires_0370af91_STOPPED_PASS.png` / `osd_pause_3883f5ab_*` | **NOT-FOUND** on worker tree |
| `overlay_FIXED_db3d9367_stopped.png` | **FOUND** 1920×1080 |

```bash
python3 tools/measure_overlay_word_span.py \
  --image files/device-evidence/overlay_FIXED_db3d9367_stopped.png \
  --expect STOPPED; echo "true rc=$?"
# ink_span_output_px=531  family=12x16
# pred_8x13@2_via640=372.0  ← matches parent hand figure 370, NOT the FIXED pixels
```

**On FIXED: parent 370 is wrong; host 531 / 12×16 is right.** Parent 370 equals the
8×13@2×(1920/640) *prediction*, not ink measured on that PNG. 3883f5ab STOPPED cannot
be re-scored without the archive.

## Panel empty-center black rectangle (silicon residual after 3883f5ab)

**Measured (parent):** inside PAUSED panel, axis-aligned dark rect ≈ HDMI x740–1190 /
rows 809–910 (store map ≈ x247–397 y360–404 @624×480), interior luma ~40 vs surrounding
chrome grey.

**RCA (source, not guess):**
- Classification **(c) empty panel interior** — not (a) a title field widget, not (b) a
  dirty-rect hole (`dirtyBounds` = full `panelBounds`).
- `playback_overlay.hpp` `render()` filled the whole panel with
  `fillRect(..., black, (170 * alpha) / 255)` and drew only icon + state label + times +
  scrubber. The band right of `PAUSED` / above the scrubber had **no content**, so
  translucent pure black over video read as a solid black rectangle.
- No `title` was ever drawn into Snapshot (confirmed across overlay history).

**Fix (ARM-only, no RTL):**
1. Opaque chrome `panelBg{42,46,54}` at full `alpha` (empty-center Y independent of video).
2. Optional media title: `setTitle` / `MediaPlayer::setOverlayTitle` / `doPlay` sets
   `resolved.title`; muted text right of state label (`fitText` truncates).

**Host gates:**
```bash
python3 tests/unit/test_panel_empty_center_static.py; echo "true rc=$?"
# red-before-green proven: ed1fc22f overlay → rc=1; current → rc=0
./build/test_playback_overlay   # section panel-empty-center: |Ywhite-Yblack|<8, Ymid~55
```

**Hardware prediction (parent deploys):**
| | PASS | FAIL |
|---|---|---|
| P1 empty-center mean luma (store map x250–390 y360–400, or HDMI equiv) | **50–70** and visually **grey chrome**, not black hole | ≤35 solid black interior |
| P2 title | muted uppercase title right of `PAUSED` when cast has `resolved.title` | blank band with black hole |
| P3 sticky PAUSED / timeline | no regression vs 3883f5ab | panel missing or bar wrong |

```bash
# after deploy new misterplexd:
# cast → play ~22s → pause → wait 6s → capture
python3 tools/readback_overlay_text.py --image CAP.png --expect PAUSED; echo "true rc=$?"
```

## Pause path canvas vs 8×13 false peak (settled)

**S1 source:** `publishPausedOverlayFrame` (`media_player.cpp`) uses
`plex480pDdrFrameGeometry()` → `renderYuv420p(yuv, cw, ch)` with product **624×480**.
Host `compute(624,480)` → **12×16@2**. Same bank as `paintIdle`.

**S2:** Silicon `osd_pause_3883f5ab_PAUSED_PASS.png` left-label exhaustive search:
`12x16@2` at norm x=76 y=349 score 0.62, `ink_span_output_px≈452` (pred 474 via624).
Old tool coarse **y-step=4** missed y=350 and picked right-side 8×13 ghost (x≈517,
score 0.55, span 341). **Not a short authoring canvas.** Fix: `coarse_y=2` + left
state-label pass + `--selftest-pause-localize`. Loud log:
`media: pause overlay canvas=624x480 font=12x16 scale=2`.


## User bug is architectural (2026-08-01)

Font/canvas authoring on the product bank is **settled at 12×16@2 / 624×480** for
both PAUSED and STOPPED. The remaining user complaint — chrome must match **MiSTer
output resolution**, not streaming content — cannot be met by ARM paint into F1 alone.

**Feasibility write-up (no fit):** [`docs/osd-output-raster-feasibility.md`](osd-output-raster-feasibility.md)

| Option | Matches user? | RBF? |
|---|---|---|
| (a) bodyScale=3 | No — larger, not sharper | No |
| (b) larger DDR bank | Partial; V_STORE=240 still caps V | Yes |
| (c) post-scale chrome plane | **Yes** | **Yes** |

Recommendation: **(c)** when an exclusive slot exists; ship black-rect ARM fix now;
do not market (a) as the resolution fix.

## Host layout at cell=48×64 (post-23b2f8df regression)

Silicon on `23b2f8df` showed font win but truncated title **`PAUSEDM`**: same-line
`"PAUSED"+"MISTERPLEX"` needs 882 px at advance=52 while panelW=594.

**Fix:** `PlaybackOverlay::computePanelLayout` places the title on a **second line**
when it cannot share the state row, grows the panel upward, and right-aligns
duration from measured `textWidth`. Gate: `tests/unit/test_overlay_layout_fit.cpp`
(RED on old same-line clip, GREEN on fit).

PREREG @624×480 Hires24x32@2: tw(PAUSED)=310, tw(MISTERPLEX)=518, panelW=594,
secondLine=1, tw(2:14)=206. Parent glass `0:30` is **not** host total-string overflow
(unknown without device `durationMs`).
