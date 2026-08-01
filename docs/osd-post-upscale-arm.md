# ARM post-upscale overlay (no RBF)

**Worker:** w-osd-hires · ARM-only · no Quartus · no device claims  
**sys/osd.v:** closed (r-misterfin) — 256×64 Main SPI OSD cannot host Plex HUD.

## T1 — Geometry chain (quoted)

### Content / DECODE tier
- Conf `DECODE=` → `MediaPlayer::setDecodeSize` → `outW_`/`outH_`  
  (`media_player.cpp` `setDecodeSize` / `outW_ = w`).
- Device lab often `DECODE=320x240` (user conf). This selects the **PMS ladder**, not the DDR bank.

### Present / coded bank (silicon constant)
```text
ddr_frame_layout.hpp:
  kPlex480pCodedWidth=624  kPlex480pCodedHeight=480
  kPlex480pDisplayWidth=618 … PresentedWidth=640 PresentedHeight=480
  ddrFrameGeometryForFpgaPresent(any) → productDdrFrameStoreGeometry()
                                      → plex480pDdrFrameGeometry()  // ignores DECODE
```

### Playback path order (`media_player.cpp` threadMain)
```text
ddrGeometry = ddrFrameGeometryForFpgaPresent(outW_, outH_)  // → 624×480
rawW/H = ddrGeometry.coded_*
vfReq.coded_w/h = rawW/H
buildFfmpegVideoFilter → scale+pad into coded bank   // UPSCALES content
// … spawn ffmpeg, read raw frames at frameBytes(rawW,rawH) …
presentCleanFrame:
  renderOverlay(cleanFrame)   // POST-UPSCALE @ rawW×rawH
  publishDdrFrame(..., ddrGeometry, Yuv420p)
```

### Overlay raster sizes
| Path | Geometry | Render call |
|------|----------|-------------|
| Play | `rawW×rawH` coded bank | `overlay_.renderYuv420p(data, rawW, rawH)` |
| Pause sticky | `plex480pDdrFrameGeometry()` | `renderYuv420p(yuv, cw, ch)` |
| Idle/stop | `plex480pDdrFrameGeometry()` | `renderRgb24` then I420 |

### RED twin (must not return)
```text
// main historical:
ddrFrameGeometryForPresentedSize(outW_, outH_)  // DECODE=320 → identity 320×240
case Yuv420p: break;                            // play overlay no-op
```

### What “output” means on this RBF (ARM-only)
- **Authoring canvas** = DDR coded bank **624×480** (presented scanout contract 640×480).
- **HDMI video_mode** (e.g. 1920×1440) is applied later by MiSTer `ascal`. ARM cannot paint true HDMI-native chrome without a post-ascal plane (separate lane; not required for this ARM-only fix).
- User modes 800×600 / 640×480 / 240p: when those are the **present canvas** (lab/fb paths), `PlaybackOverlay::compute(w,h)` scales metrics. Product FPGA path stays 624×480 bank.

### 240p policy
- `h < 480` → font **8×13**, `bodyScale≥2`, panel clamped to `h - 2*margin` (no overflow).
- `h >= 480` → **12×16** at `bodyScale==2` (product bank).

## Gates
- `test_overlay_post_upscale` — FpgaPresent(320)→624; metrics present>content
- `test_overlay_raster_geometry_static` — no PresentedSize(outW_); Yuv render required
- G0 `test_chrome_output_layout_static` — HDMI-layout helper (future plane)

## Device card
See `.agent-work/w-osd-hires/DEVICE_CARD_post_upscale.md`
