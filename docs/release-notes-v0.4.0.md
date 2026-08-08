# MiSTerPlex v0.4.0

Multi-resolution cast release: **240p / 480p / 720p**, live PMS encoder match, DDR present always on.

## Highlights

- **Content resolution labels:** OSD and product profiles use **240p / 480p / 720p** (CONF_STR v8 `O[5:4]`). Internal banks remain 320×240, 640×480 (624 coded), 1280×720.
- **Live PMS match:** Changing content resolution retargets the Plex universal weak ladder (`videoResolution` + bitrate/profile) and restarts the session at the same playhead. Lab SCORE: 240p→`320x240`, 480p→`640x480`, 720p→`1280x720` on FOAR cast. FFmpeg FOAR+pads when source ≠ bank (never trust `videoResolution` alone — L38). Scale bypass only for exact Media size match or local identity.
- **Plex cast E2E:** Playwright against local PMS Web (`http://<pms>:32400/web`) + companion remote-player APIs (play/pause/resume/seek/stop/timeline) + HDMI-USB glass PASS. Video-only titles (e.g. Grid720) no longer abort when `AUDIO=on` (L39). Content modes 240p/480p/720p each request matching PMS `videoResolution` on the weak ladder.
- **DDR always available:** HPS DDR frame store is the shipping present path. **SDRAM stick is optional** — not required for 240p/480p/720p. Conf documents `PRESENT_MEM=auto|ddr`.
- **480p geometry:** FOAR+pad contract coded 624 × display 618 × present 640 (lab-proven in daemon logs).
- **Companion version:** 0.4.0.

## Rate honesty (720p)

| Path | Typical pfps (lab FOAR / identity) | Notes |
|------|-------------------------------------|--------|
| 720p PMS cast + audio (DDR) | ~9–16 class | Dual-A9 decode + uncached bank copy; under-run smooth, drops≈0 |
| 720p local identity play-file | ~21+ | Present pipeline headroom; not product cast |
| 240p / 480p PMS + audio | ~22 | Near content rate with A/V lock |

**Do not claim 720p@24 product** until a SCORE card shows sustained `vfps/pfps≥23.5` for ≥120s on the shipping RBF with audio. G1-min ship is **stable DDR 720p** without corruption; 24 fps remains the stretch goal (DMA/WC publish path).

## Known limits

- Plex Web header “Select Player” may show MiSTerPlex; Play/Resume without an active remote target still plays in the browser. Product control path is PMS target-client `/player/playback/*` (what Web uses for cast targets).
- Freckle/chevron fabric polish may still be open on the freckle ladder; chevron non-regress required for ship RBF.
- Live OSD 720p rung requires **v8** core; v7 `O[4]`-only still maps 240p/480p. Daemon understands both.
- Kernel DMA / write-combine full-frame ingest not product-default yet.

## Package

Pinned RBF: `release_artifacts/v0.4.0/Plex.rbf`  
md5 **`d7412bf8531bba4d1402250c3e8bead7`** (softc24 HOLD=2 + CONF_STR v8 240p/480p/720p).  
Fit: ALM 76%, M10K bits 24%, DSP 38%, STA setup slack +0.353.  
Package: `VERSION=v0.4.0 RBF_MD5_EXPECTED=d7412bf8531bba4d1402250c3e8bead7 scripts/package_release.sh`.

## Upgrade notes

1. Deploy new `misterplexd` + conf example keys (`TRANSCODE_PROFILE=240p|480p|720p`, `PRESENT=fpga`).
2. Deploy v8 `Plex.rbf` when fitted; reset OSD once (`v,8`) so content-res bits clear.
3. Optional: enable `OSD_CONTROL=1` for live content-res from F12.
