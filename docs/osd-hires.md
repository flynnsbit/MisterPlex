# OSD / playback chrome sharpness (w-osd-hires)

Status: ARM implementation + lattice criterion tool.  
Related: `host/libmisterplex/playback_overlay.hpp`, `host/libmisterplex/idle_screen.hpp`,
`arm/misterplexd/media_player.cpp`, `fpga/Plex_MiSTer/rtl/present_core.sv`,
`tools/measure_overlay_edge.py`, `.agent-work/w-cpu/OSD_HIRES_CPU_BUDGET.md`.

## Parent supersede brief (source of truth)

Earlier “composite at 1080p HDMI” and “10–90% edge ≤2 px” targets are **withdrawn**.

1. **RTL DE ceiling:** `present_core.sv` uses `H_DE=529`, `V_STORE=240`, and
   `STORE_Y_SCALE=(FRAME_H*65536)/240`. With product `FRAME_H=480` that is exactly
   2.0 in 16.16, so scanout only ever fetches **even** store rows (0,2,…,478).
   Half the vertical detail in the 480-row bank is discarded; ascal then scales
   ~529×240 → HDMI. That alone explains ~4–6 px soft edges and ~3–4 row pitch on
   1080p captures — without any ARM compositing theory.
2. **Product YUV path painted no transport overlay:** base
   `media_player.cpp` `case RawVideoFormat::Yuv420p: break;` and
   `playback_overlay.hpp` had only RGB renderers. Shipping `PRESENT=fpga` +
   `DDR=yuv420p` therefore had **no** `PlaybackOverlay` pixels during playback.
   This work **adds** `renderYuv420p`, it does not optimise an existing blend.
3. **Acceptance metric:** edge-position **lattice pitch** (and diagonal stair runs)
   on the analysis raster — **not** 10–90% transition width (NN sharpening games
   that metric). Executable: `tools/measure_overlay_edge.py`.

## Step 1 — Who draws what (quoted paths)

| Surface | Renderer | Notes |
|---|---|---|
| Idle chevron / screensaver | `idle_screen.hpp` (`renderIdleRgb24` / `renderIdleYuv420p`) | Parent `idle_warm.png` is this class |
| Transport panel, timeline, icons, skip, notices | `playback_overlay.hpp` | Base product YUV: **no-op** until this branch |
| Main F12 menu | `sys/osd.v` | Not Plex transport |
| companion / osd_control / fpga_spi | control / transport | No chrome pixels |

**PRESENT=fpga end-to-end format:** YUV420p F1
(`media_player.cpp` wantYuvDdr → `RawVideoFormat::Yuv420p`; DDR publish refuses non-YUV).

**Base renderOverlay YUV:** `break;` — code proof of no paint (strong).  
`overlay_cpu_us_p=0` is only weak corroboration (also true if overlay not visible).

**Idle vs transport:** different authors, same sink when both hit F1:
coded canvas → DDR → `present_core` DE 529×240 → ascal → `video_mode`.

This worktree unifies `paintIdle` to the **coded** canvas (drops fb0-only 320×240
idle authoring) so idle and transport share one layout scale on the product path.

## Step 2 — Resolution sources

| Quantity | Source | Daemon |
|---|---|---|
| HDMI mode | MiSTer.ini `[Plex] video_mode` → ascal | **Not read** today |
| Presented / coded bank | RTL `FRAME_*` / `CODED_*` (640×480 / 624×480) | `ddr_frame_layout.hpp` |
| DE raster | `H_DE`×`V_STORE` (529×240) | Fixed in `present_core.sv` |
| Decode tier | OSD mailbox | `outW_/outH_` — content, not chrome |

Chrome layout is a function of the **buffer passed to render\*** (present/coded
canvas), with proportional metrics so 800×600 / 640×480 / 240p-class buffers
stay legible. Live HDMI WxH is not required for that.

Raising `V_STORE` / changing `STORE_Y_SCALE` is the only way to lift the 240-line
ceiling; that needs exclusive Quartus and is **out of scope** until ARM 1–3 prove
insufficient.

## Step 3 — Design (cheapest path that matches the brief)

### Compositing point

Keep compositing **into the existing coded/present buffer** (pre-DDR), **after**
any content letterbox into that buffer and **before** F1 publish. Do **not**
composite at HDMI resolution — fabric would throw away the extra vertical samples
and ARM cost would be pure waste.

### Layout model

Metrics from buffer `W×H`, snap to integers (see `layoutMetrics()`):

- margins / panel height as fractions of W/H with clamps for 240p and large canvases
- timeline bar thickness and icon boxes proportional
- **bodyScale = 1 always** — never block-upscale glyphs

### Text / icons

**8×13 (class) bitmap font at `scale=1`**, replacing 5×7 drawn as `scale×scale`
blocks. Same on-screen footprint gains ~4–5× glyph detail and costs **less** than
5×7@scale=4. Icons redrawn as formed bitmaps/rects at native cells, not giant
`fillRect` diamonds from content-pixel literals.

### CPU

Dirty strip ~`W × ~panelH` (order 624×60 ≈ 37k px) only while overlay visible (~3 s).
Cheaper than full-frame walks already done every frame
(`clearYuv420pCropPadding`, `repairDeadYuv420pChroma`). See w-cpu budget note:
always-on 1080p composite rejected; dirty bursts OK; watch present deadline spikes.

### Criterion tool

`tools/measure_overlay_edge.py`:

- Coarse gap mode among gaps **≥2**: fail if mode ∈ {3,4,5,6} with share ≥ 0.40
- Diagonal stair: fail if unique-X ≥ 8 and share(run≥3) ≥ 0.28
- Legibility floors on stroke/cap when runs exist
- Selftest: native 529×240 **PASS**, blocky×4 **FAIL**
- Proven **RED** on parent archive `idle_warm.png` (1080p HDMI): `true rc=1`
- Score HDMI captures at capture res; nearest 1080→DE **erases** lattice (do not
  require `--de-resample` for archive RED proof)

### Golden / units

- `tests/unit/test_playback_overlay.cpp` + regenerated
  `golden/playback_overlay_rgb565.txt` for 8×13 layout
- Multi-res overflow, content-independence (same W×H two “content” stories →
  identical overlay), YUV path smoke, glyph quality vs 5×7-upscale
- `tests/unit/test_overlay_edge_measure.sh` gates the tool


## Pause / play overlay path (parent hardware proof)

Parent captured STOPPED chrome on HDMI (`overlay_lowres_evidence.png`) from
`paintIdle()` + `overlay_.renderRgb24` at coded 624×480. Pause on shipping
silicon produced **frozen frames with no chrome** (`delta_prev=0`) because:

1. YUV `renderOverlay` was a no-op (fixed: `renderYuv420p`).
2. `pause()` SIGSTOP’d FFmpeg while the play thread could be blocked in `read()`,
   so the in-loop pause presenter never ran.
3. STREAM skip-RGB only slept on pause.

**Fix:** `rememberPauseFrame` latches each clean YUV F1; `pause()` calls
`publishPausedOverlayFrame()` **before** SIGSTOP; STREAM skip-RGB pause loop
also publishes while the overlay is visible. Fonts: 8×13 when `H<360`, 12×16
when `H≥360` (CC0 hand-authored bitmaps), always `scale=1`.

## Step 4 — Implementation map

- `playback_overlay.hpp` — metrics, 8×13 font, scale=1 text/icons, `renderYuv420p*`
- `media_player.cpp` — YUV `renderOverlay` branch; YUV dirty backup; idle coded canvas
- `tools/measure_overlay_edge.py` + unit shell
- Golden regen deliberate (font/layout change), not to silence red

## Step 5 — Unit evidence

```bash
make -C .worktrees/w-osd-hires build/test_playback_overlay && \
  .worktrees/w-osd-hires/build/test_playback_overlay; echo "true rc=$?"
bash .worktrees/w-osd-hires/tests/unit/test_overlay_edge_measure.sh; echo "true rc=$?"
```

## Step 6 — Device verification (parent only)

Worker does **not** touch the device.

```bash
# Deploy ARM daemon only (no core thrash):
DEPLOY_LOAD=none ./scripts/deploy_misterplexd.sh

# Idle @ 1080p (MiSTer.ini [Plex] video_mode=8):
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 1 -y build/pair-visual/idle_after_osd_hires.png
python3 tools/measure_overlay_edge.py build/pair-visual/idle_after_osd_hires.png
# Print must include true rc=. Archive baseline is true rc=1 (FAIL lattice).

# Transport: cast → pause with timeline visible → same capture + tool on panel crop.
# Expect: overlay actually present on PRESENT=fpga YUV (new path). Lattice on the
# DE-limited path will not reach pitch-1 at 1080p until V_STORE work; compare
# glyph cell detail vs pre-change 5×7@scale blocks at matched video_mode=6 (640×480)
# where ascal scale≈1 for a fair chrome-detail check.

# Optional matched-mode control:
#   video_mode=6 (640×480), pause, capture, score — chrome should be DE-native sharp
#   relative to 1080p upscale of the same buffer.
```

**Falsifiable pass (ARM scope):**  
On a pause capture with `PRESENT=fpga`, Y plane of coded buffer (or HDMI at
`video_mode=6`) shows transport chrome; `measure_overlay_edge.py` on a **DE-native
or scale≈1** capture of that chrome reports `VERDICT=PASS` (no dominant pitch 3–6,
stair_share_ge3 low). HDMI 1080p may remain lattice-FAIL while `V_STORE=240` —
that is the fabric ceiling, not an ARM regress; archive RED proof stays the
tool’s regression anchor.
