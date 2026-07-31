# OSD / playback overlay at output resolution

Status: design + ARM implementation (worker `w-osd-hires`).  
Related: [`display-resolution.md`](display-resolution.md), `host/libmisterplex/playback_overlay.hpp`,
`arm/misterplexd/media_player.cpp`.

## Step 1 — Real overlay path (evidence)

| Path | What draws pixels | Size used | HDMI? |
|---|---|---|---|
| **Playback RGB/565/BGRA** | `presentCleanFrame` → `renderOverlay` → `overlay_.renderRgb*`(data, **rawW, rawH**) then `blitFrame` / (non-YUV) refused for F1 | `rawW/H` = DDR **coded** geometry (`media_player.cpp` ~2250–2251, 2852–2866, 2902–2999) | Only if something else presents; product F1 is YUV-only |
| **Playback YUV420p (product `PRESENT=fpga`)** | `case RawVideoFormat::Yuv420p: break;` — **no overlay pixels** (`media_player.cpp` 2860–2861) | n/a | Video yes; transport overlay **was a no-op** |
| **Pause loop** | Re-calls `presentCleanFrame` on last frame while `overlay_.visible()` (3038–3047) | same as above | same gap on YUV |
| **Idle notice** | `paintIdle`: RGB24 overlay at 320×240 for fb0; when `overlay_.visible()`, RGB at **coded** W×H then RGB→YUV for DDR (739–820) | 320×240 or coded canvas | Yes on DDR when notice visible |
| **MiSTer F12 OSD** | Framework `sys/osd.v` (Main), not `PlaybackOverlay` | fixed OSD buffer | Separate chrome |

**Contradiction vs earlier note:** on product YUV DDR, the transport panel was **not** composited into the frame at all. RGB paths *do* composite pre-ascal into the coded buffer (mechanism for “blocky when HDMI-scaled”). Idle notices *do* reach HDMI via RGB→YUV at coded size.

Compositing order today (RGB): decode/scale → **overlay into content/canvas buffer** → present → MiSTer **ascal** to `video_mode`. Overlay is enlarged with the picture.

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

**Hard limit:** product F1 is coded 624×480 (presented 640×480). True **HDMI-pixel-sharp** chrome needs a post-ascal plane (framework OSD or new RTL). This change makes overlay **canvas-native**, resolution-scaled, and **actually drawn on YUV**, which is the maximum quality on the current silicon path.

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

See agent status `PARENT_ACTION` / recipe at end of implementation. Falsifiable: on pause at `video_mode=8`, glyph stroke width in capture ≥ N HDMI pixels; panel bottom margin scales with mode; overlay geometry unchanged when switching content tier 320 vs 624 with same `video_mode`.
