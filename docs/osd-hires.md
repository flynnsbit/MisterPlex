# OSD / playback overlay at output resolution

Status: design + ARM implementation (worker `w-osd-hires`).  
Related: [`display-resolution.md`](display-resolution.md), `host/libmisterplex/playback_overlay.hpp`,
`host/libmisterplex/idle_screen.hpp`, `arm/misterplexd/media_player.cpp`,
`tools/measure_overlay_edge.py`.

## Parent HDMI evidence (idle, not only transport)

Capture: `.worktrees/rollback-honest/build/pair-visual/idle_warm.png` (1920×1080 idle chevron).

| Measurement | Value | Meaning |
|---|---|---|
| 10–90% luma edge ramp | ~6 samples (tool: edge_max≥5 on archive) | Soft edge from low-res source + ascal |
| Vertical detail pitch | mode ~3 rows | ~640×480 canvas → 1080p (1920/640≈3) |

**Falsifiable pass criterion (executable):**  
`tools/measure_overlay_edge.py CAPTURE.png` → `true rc=0` only if 10–90% edge width ≤2 **and** no coarse 3/4-row diagonal stair pitch.  
Proven **RED** on the archived capture (`true rc=1`) and on bilinear 640→1080 selftest; **GREEN** on native-1080 authored chevron (`--selftest`).

Idle chevron, notice banners, and transport panel are **one problem class**: chrome authored at canvas (or worse 320×240) then ascal’d to HDMI.

## Step 1 — Real overlay path (evidence)

| Path | What draws pixels | Size used | HDMI? |
|---|---|---|---|
| **Playback RGB/565/BGRA** | `presentCleanFrame` → `renderOverlay` → `overlay_.renderRgb*`(data, **rawW, rawH**) then `blitFrame` / (non-YUV) refused for F1 | `rawW/H` = DDR **coded** geometry (`media_player.cpp`) | Only if something else presents; product F1 is YUV-only |
| **Playback YUV420p (product `PRESENT=fpga`)** | **Was** `case Yuv420p: break;` (no-op). **Now** `overlay_.renderYuv420p` + strided dirty backup | coded canvas | Video + transport on F1 |
| **Pause loop** | Re-calls `presentCleanFrame` on last frame while `overlay_.visible()` | same | YUV path now draws |
| **Idle chevron + notice** | `paintIdle` → `renderIdleRgb24` + `overlay_.renderRgb24` at **product coded** W×H, RGB→YUV publish (`media_player.cpp` paintIdle). **Was** fb0 hard-coded 320×240 | coded 624×480 product | Yes via DDR F1 → ascal |
| **MiSTer F12 OSD** | Framework `sys/osd.v` (Main), not `PlaybackOverlay` | fixed OSD buffer | Separate chrome |

**Open question resolved:** product YUV path previously skipped transport overlay (`break;`). User-visible pause chrome on pure `PRESENT=fpga` was therefore **idle notices and/or a non-YUV path**, not the broken YUV branch. Idle art always reached HDMI via `renderIdleYuv420p` / RGB→YUV at **coded** size — matching the parent’s 3-row pitch at 1080p (`presented 640` → `video_mode=8`).

Compositing order: decode/scale → **chrome into coded canvas** → DDR/fb0 → core scanout → **ascal** → HDMI `video_mode`. Canvas-native chrome is sharp only when `video_mode` ≈ presented size; at 1080p ascal still softens.

## Step 2 — Where output resolution comes from

| Quantity | Source of truth | Daemon today |
|---|---|---|
| HDMI/VGA **output** mode | MiSTer.ini `[Plex] video_mode=*` → ascal (`docs/display-resolution.md`) | **Not read.** No SPI/status word for live HDMI timing in misterplexd. |
| Core **presented** canvas | RTL `FRAME_W/H` (product 640×480) / DDR layout | `ddr_frame_layout.hpp` / `plex480pDdrFrameGeometry()` |
| Core **coded** bank | RTL `CODED_W/H` (624×480 product) | `ddrFrameGeometryForFpgaPresent()` — silicon constant |
| Content tier (PMS/decode) | OSD `O[5:4]` via mailbox/SPI | `osd_menu.hpp` → `outW_/outH_` |
| Linux fb0 size | `FBIOGET_VSCREENINFO` | `FbPresent::width()/height()` only if fb opened (`PRESENT=fb0\|both`) |

**Measured:** product publish path always uses coded 624×480 for FPGA DDR (`ddrFrameGeometryForFpgaPresent` ignores decode WxH).  
**Assumed / not available without new plumbing:** live HDMI 1920×1080 vs 800×600 inside the daemon.

**Cheapest reliable output hint (no RTL):** parse `[Plex] video_mode` from `/media/fat/MiSTer.ini` (same table as `display-resolution.md`) **or** conf `OVERLAY_OUTPUT=WxH`. That yields layout intent for tests and future post-ascal planes; it **cannot** put more pixels into the fixed DDR bank.

**Hard limit (silicon):** product F1 is coded 624×480 (presented 640×480, `Plex.qsf` `FRAME_W=640`). True **HDMI-pixel-sharp** chrome at `video_mode=8` (1920×1080) needs either:
1. a larger frame store / post-ascal plane (RTL / Quartus exclusive), or
2. `video_mode` matched to the canvas (e.g. mode 6 = 640×480) so ascal scale≈1.

ARM-only work cannot meet the ≤2 px edge criterion at 1080p while pixels still leave the core at 480p — the parent’s 3-row pitch is geometric. This change makes chrome **canvas-native** (not 320×240), resolution-scaled, and **actually drawn on YUV**, which is the maximum quality on the current F1 path.

## Step 3 — Design

### Where compositing moves

1. FFmpeg (or recon) produces a frame already scaled/padded to the **present canvas** (`rawW×rawH` coded).
2. **After** that scale/pad, `presentCleanFrame` composites the overlay into the canvas buffer (RGB\* or **YUV420p**).
3. Publish canvas to DDR / fb0.
4. MiSTer ascal scales canvas → HDMI `video_mode` (unchanged).

Overlay layout uses the **buffer size passed to render\*** (the present canvas), never a separate decode-tier constant. Decode tier may change PMS ladder; canvas stays product geometry on `PRESENT=fpga|both`.

### Resolution-independent layout

Define metrics from output (buffer) `W×H`, snap to ints:

| Metric | Formula (snap) | 240p | 480p canvas | 800×600 | 1080p buffer |
|---|---|---:|---:|---:|---:|
| margin | `max(8, W/32)` | 10 | 19 | 25 | 60 |
| panelH | `clamp(H/4, 54, max(72, H/5))` | 60 | 96 | 120 | 216 |
| bodyScale | `max(1, H/200)` | 1 | 2 | 3 | 5 |
| titleScale | `bodyScale` | 1 | 2 | 3 | 5 |
| icon | `~10×bodyScale` px half-extent | ~10 | ~20 | ~30 | ~50 |
| barH | `max(4, panelH/12)` | 5 | 8 | 10 | 18 |
| skip/notice boxH | `max(28, 14×titleScale)` | 28 | 28 | 42 | 70 |

**Minimum legible:** bodyScale≥1; at 240p keep single-pixel 5×7 (legacy).  
**Degrade at 240p:** drop secondary labels if panel overflows; clamp panel to frame; skip box may dominate center briefly.

### Text / icon quality

**Choice: multi-size integer scale of the existing 5×7 bitmap** (`bodyScale = max(1, H/200)`).

| Option | Quality | CPU on dual-A9 | Notes |
|---|---|---|---|
| Larger multi-size 5×7 (chosen) | Blocky but sharp edges; stroke width ∝ H | Low — fillRect blocks, dirty-rect only | No new assets |
| Vector-ish strokes | Smoother diagonals | Medium | More code, little gain at 480p |
| AA supersample | Best | High (extra buffer + filter) | Rejected: overlay ~3 s, but 1080p dirty still large; ARM headroom tracked on soak |

### CPU cost (order-of-magnitude)

Dirty panel ≈ `W × panelH` blends. Per visible frame (≤ ~3 s @ ~24–30 present/s when shown):

| Canvas | Dirty px (panel) | RGB blend cost vs 624×480 baseline |
|---|---:|---|
| 624×480 (product) | ~624×96 ≈ 60k | **1.0×** (and now YUV path actually draws) |
| 320×240 | ~300×60 ≈ 18k | ~0.3× |
| 1920×1080 (if ever buffered) | ~1920×216 ≈ 415k | ~7× — still only while overlay visible; dirty-rect keeps steady-state zero |

YUV path: Y write + 2×2 chroma refresh in dirty rect ≈ 1.2–1.5× RGB565 cost.  
Backup/restore dirty for YUV is plane-strided memcpy (not bpp=0 skip).

### Golden / unit compatibility

- `tests/unit/test_playback_overlay.cpp` + `golden/playback_overlay_rgb565.txt` lock **320×240**, scale-1 geometry.
- Layout formulas **preserve** 320×240 panel dirty `10 170 300 60` and prior progress bar anchors so the existing golden stays valid.
- New tests cover 1920×1080, 800×600, 640×480, 320×240 overflow, content-independence, and glyph stroke width at large H (red on forced scale=1).

## Step 4–5 — Implementation map

- `host/libmisterplex/playback_overlay.hpp` — `LayoutMetrics`, scaled draw, `renderYuv420p*`.
- `arm/misterplexd/media_player.cpp` — YUV branch calls `renderYuv420p`; YUV dirty backup/restore.
- Tests — extend `test_playback_overlay.cpp` (+ optional `test_playback_overlay_hires.cpp` if rollcall needs a second binary).

## Step 6 — Device verification (parent only)

Worker must not touch the device. Parent recipe:

```bash
# 1) Deploy ARM only (no core thrash):
DEPLOY_LOAD=none ./scripts/deploy_misterplexd.sh   # or project-equivalent

# 2) Capture idle at 1080p (MiSTer.ini [Plex] video_mode=8):
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 1 -y build/pair-visual/idle_after_osd_hires.png

# 3) Score (must print true rc=):
python3 tools/measure_overlay_edge.py build/pair-visual/idle_after_osd_hires.png
# Expect while F1 remains 480p canvas: true rc=1 (edge_max>2) — documents silicon limit.
# Expect after future native-1080 plane: true rc=0 (edge_max<=2, pitch_ok).

# 4) Matched-mode control (video_mode=6 / 640x480). Capture may need mode-matched size:
#    edge criterion should approach PASS if ascal scale≈1 and chrome is canvas-authored.

# 5) Transport overlay: pause cast, capture, same tool on the panel edge.
```

Pass criterion (parent): 10–90% luma transition ≤2 output px; no 3–4 row diagonal stair pitch.
