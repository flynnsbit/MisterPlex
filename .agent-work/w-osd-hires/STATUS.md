# w-osd-hires — user bug #2 status (honest)

## Shipped state (nothing deployed by parent)

| Item | Value |
|------|--------|
| Branch | `w-osd-hires` (worktree `.worktrees/w-osd-hires`) |
| Core fix commit | `6b1b68c7` — post-upscale overlay at DDR bank |
| Native plane scaffold | `ff16f253` — fail-closed `CHROME_PLANE` |
| Tip (pre this status push) | `aa11609e` |
| Merged to main | **NO** |
| Deployed to device | **NO** (parent-only) |
| Daemon binary (last arm-plexd) | see `DAEMON_MD5.txt` after rebuild |

## What the fix does (plane=0 product path)

1. **Authoring canvas** = silicon DDR bank via `ddrFrameGeometryForFpgaPresent` → **624×480 coded** (not DECODE 320×240).
2. FFmpeg still scales content into that bank (**load-bearing**; pad-only closed).
3. `renderOverlay` runs **after** pipe read / on the bank-sized buffer, including **Yuv420p** (`renderYuv420p`).
4. Layout metrics from `OverlayLayoutMetrics::compute(rawW,rawH)` → 12×16 @ scale 2 on bank h=480.

## What it does NOT do yet

- **Not HDMI-native pixels.** Bank is still stretched by ascal to `video_mode`. True 1:1 output-res text needs plane=1 RTL (fail-closed today) **and** 240-row ceiling lift (w-fit-1).
- Do **not** claim pixel-perfect output-res text until parent confirms ceiling lift on glass + plane path.

## Measured output geometry (not hardcoded 1920×1080)

| Source | Role | Evidence |
|--------|------|----------|
| `loadMisterVideoMode()` / `MiSTer.ini` `[Plex] video_mode=` | **Measured** HDMI preset/custom WxH for logs + plane=1 layout | `mister_video_mode.hpp` |
| Missing/unparsed ini | `output=DEFAULT_ASSUMED` — **does not invent** 1080p; bank authoring unchanged | `overlayOutputGeomTag()` in `media_player.cpp` |
| Live ascal W×H from core | **NONE on this RBF** | no SPI status word wired |
| Authoring size plane=0 | Silicon constant **624×480** (`plex480pDdrFrameGeometry`) | `ddr_frame_layout.hpp` |

Log tag example: `output=1920x1440 mode=12 source=ini authoring=624x480` or `output=DEFAULT_ASSUMED mode=? source=none authoring=624x480`.

## Resolution-adaptive policy

| Mode | Layout API | bodyScale | Font | 240p policy |
|------|------------|-----------|------|-------------|
| Bank F1 (product) | `compute(w,h)` | ≥2, 3 if h≥720 | 12×16 if h≥480 else 8×13 | N/A (bank h=480) |
| Output / plane=1 | `fromOutputLayout` / `computeOutputChromeLayout` | half-to-even round(H/240) clamp 2..8 | large if H≥480 | scale≥2, **8×13**, panel clamped in-bounds; min cellH=26 |

User modes pinned in `test_overlay_crispness_mutation`: 1080p→scale4, 800×600→2, 640×480→2, 240p→2 small font.

## Host gates (no `readback_overlay_text.py`)

| Gate | RED proof | GREEN |
|------|-----------|-------|
| `test_overlay_raster_geometry_static.py` | fails main (no FpgaPresent / Yuv break) | tip rc=0 |
| `test_overlay_post_upscale_red_main.sh` | compiles main twin RED | tip twin GREEN |
| `test_overlay_crispness_mutation` | content→NN grad **22.4 < 30** floor (mutant rc=1) | bank paint grad **38.0 ≥ 30** rc=0 |

## Parent device card

See `SHIP_RUNBOOK.md`. Need PAUSED chrome held ≥8–10 s. Expect log `pause overlay canvas=624x480 font=12x16 scale=2` + `authoring=624x480`. Pair RBF md5 + daemon md5 on any glass claim.
