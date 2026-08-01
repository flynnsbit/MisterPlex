# Parent reply — F12 banner + user bug #2 status

## (1) `F12 IDLE: USE CONF` banner — source quote

**Not a surprise state. Intentional product notice for F12-inert OSD, not the logo itself.**

Definition:
```cpp
// host/libmisterplex/osd_control.hpp
inline const char* osdInertUserNotice() {
    return "F12 Idle: use conf";
}
```

Paint path (deployed `f3aa2443` / tip before this reply gated it):
```cpp
// arm/misterplexd/media_player.cpp — startOsdPoll inert branch
overlay_.flashNotice(osdInertUserNotice());  // 8s notice (kNoticeVisibleMs)
if (!playing_.load())
    paintIdle();
// paintIdle():
renderIdleRgb24(...);           // chevron / logo
overlay_.renderRgb24(...);      // composites notice OR STOPPED transport if visible
```

Triggered when F12 cannot drive idle (`OSD_CONTROL=off`, or Auto settles `Absent`/`PreV3`). Logs always said *Idle Screen menu does nothing; use IDLE_SCREEN conf*.

**With `IDLE_SCREEN=logo` the chevron still paints; the banner is extra chrome from the inert notice**, not a different idle mode.

### Change in this tip
HDMI flash is **opt-in** conf `OSD_INERT_NOTICE=1` (**default off**). Logs still emit. Clean logo idle is the product default.

---

## (2) User bug #2 — does transport render on product YUV path in `f3aa2443`?

**YES during PLAY and PAUSE.** The old `case Yuv420p: break;` defect is fixed on this branch (in `f3aa2443`).

```cpp
// media_player.cpp renderOverlay — product path
case RawVideoFormat::Yuv420p:
    overlay_.renderYuv420p(data, rawW, rawH);  // NOT break;
    break;
// presentCleanFrame → renderOverlay(cleanFrame) when dirty && !chromePlaneLive()
```

Pause republish:
```cpp
// publishPausedOverlayFrame
const DdrFrameGeometry g = plex480pDdrFrameGeometry(); // 624×480
overlay_.renderYuv420p(yuv.data(), cw, ch);
publishDdrFrame(...);
```

### Where dimensions are chosen (not HDMI output)

```cpp
// threadMain
wantFpgaDdrCanvas ? ddrFrameGeometryForFpgaPresent(outW_, outH_)
                  : makeDdrFrameGeometry(outW_, outH_);
// → product PRESENT=fpga: always plex480p **624×480 coded**
const int rawW = ddrGeometry.coded_width.get(); // 624
const int rawH = ddrGeometry.coded_height.get(); // 480
// overlay paints at rawW×rawH; FFmpeg already scaled content into that bank
```

`outW_/outH_` = DECODE ladder only. Overlay authoring on plane=0 = **silicon bank**, not `video_mode` HDMI raster.

**Honest ship status vs user words:**
| Claim | Status on `f3aa2443` / tip |
|-------|---------------------------|
| Overlay during play/pause YUV | **YES** (not empty break) |
| Not content 320×240 soft mush | **YES** (bank 624×480 post-upscale) |
| Matches **MiSTer output** (1080p/800/640/240) 1:1 | **NO** — still bank; ascal stretches. Needs plane=1 + ceiling lift |
| Adaptive metrics for true output | Implemented as `fromOutputLayout` / `computeOutputChromeLayout`; **not live on plane=0 product path** |

Host gate pins the gap: `bank_cellH=32` vs `hdmi1080_cellH=64`.

---

## Capture card (parent)

```bash
# Deploy tip daemon only (no RBF). Expect clean chevron, NO "F12 Idle: use conf".
md5sum .worktrees/w-osd-hires/build/arm/misterplexd
# After idle settle ≥10s (no recent stop STOPPED flash):
ffmpeg ... -y /tmp/idle_logo.png   # expect chevron only, centred

# Pause hold ≥8s during cast:
# log: pause overlay canvas=624x480 font=12x16 scale=2 authoring=624x480 plane=0
# SEE: transport panel sharper than content-tier 320 path, still bank-res not HDMI-native
```
