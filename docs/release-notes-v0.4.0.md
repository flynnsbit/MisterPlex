# MiSTerPlex v0.4.0

Multi-resolution cast release: **240p / 480p / 720p**, live PMS encoder match, DDR present always on.

## Highlights

- **Content resolution labels:** OSD and product profiles use **240p / 480p / 720p** (CONF_STR v8 `O[5:4]`). Internal banks remain 320×240, 640×480 (624 coded), 1280×720.
- **Live PMS match:** Changing content resolution retargets the Plex universal weak ladder (`videoResolution` + bitrate/profile) and restarts the session at the same playhead. Lab SCORE: 240p→`320x240`, 480p→`640x480`, 720p→`1280x720` on FOAR cast. FFmpeg FOAR+pads when source ≠ bank (never trust `videoResolution` alone — L38). Scale bypass only for exact Media size match or local identity.
- **Plex cast E2E:** Playwright against local PMS Web (`http://<pms>:32400/web`) + companion remote-player APIs (play/pause/resume/seek/stop/timeline) + HDMI-USB glass PASS on **240p, 480p, and 720p**. Video-only titles (e.g. Grid720) no longer abort when `AUDIO=on` (L39).
- **Timeline scrubber:** Companion reports **advancing** playback `time=` while casting (DDR 2-slot ring `onProgress` + plant-hold release from `0abee0b6`). PMS `/:/timeline` uses real HTTP **2xx** + **cast token** (not conf token on foreign `plex.direct` hosts) so Plex Web “Now Playing” / scrubber tracks the player (L40/L41 / `eeae7943`). Pause/resume/seek/stop verified on all three modes.
- **DDR always available:** HPS DDR frame store is the shipping present path. **SDRAM stick is optional** — not required for 240p/480p/720p. Conf documents `PRESENT_MEM=auto|ddr`.
- **480p geometry:** FOAR+pad contract coded 624 × display 618 × present 640 (lab-proven in daemon logs).
- **Companion version:** 0.4.0.

## Ship-accepted present rates (lab, DDR path)

| Mode | Content | Typical pfps | Audio |
|------|---------|--------------|-------|
| 240p | FOAR A+V | ~24–25 | advances with picture |
| 480p | FOAR A+V | ~24 | advances with picture |
| 720p | FOAR A+V | ~13–16 | advances with picture |
| 720p | Grid720 video-only | ~18–19 | n/a (source has no audio stream) |

These are the product rates for v0.4.0. Playback is stable with A/V lock; under-runs are smooth (drops≈0). Further 720p rate headroom (KernelDma / write-combine) is a **future enhancement**, not a withheld ship feature.

Evidence: `Memory/lab/status/SCORE_v040_MATRIX_WEB_TIMELINE.txt` (OVERALL PASS).

## Operational notes

- Plex Web header “Select Player” may show MiSTerPlex; Play/Resume without an active remote target can still play in the browser. Product remote control is PMS target-client `/player/playback/*` (same path Web uses for cast targets).
- Live OSD 720p rung requires **v8** core; v7 `O[4]`-only still maps 240p/480p. Daemon understands both.
- Named `TRANSCODE_PROFILE=240p|480p|720p` owns the weak ladder. Sticky `WEAK_BITRATE` / `WEAK_RES` conf overrides can pin the wrong ladder — clear them when switching modes.

## Package

Pinned RBF: `release_artifacts/v0.4.0/Plex.rbf`  
md5 **`d7412bf8531bba4d1402250c3e8bead7`** (softc24 HOLD=2 + CONF_STR v8 240p/480p/720p).  
Fit: ALM 76%, M10K bits 24%, DSP 38%, STA setup slack +0.353.  
Package: `VERSION=v0.4.0 RBF_MD5_EXPECTED=d7412bf8531bba4d1402250c3e8bead7 scripts/package_release.sh`.

## Upgrade notes

1. Deploy new `misterplexd` + conf example keys (`TRANSCODE_PROFILE=240p|480p|720p`, `PRESENT=fpga`, `AUDIO=on`).
2. Deploy v8 `Plex.rbf` when fitted; reset OSD once (`v,8`) so content-res bits clear.
3. Optional: enable `OSD_CONTROL=1` for live content-res from F12.
4. Prefer `--conf /media/fat/misterplex_v2/misterplex.conf` (or keep default `/media/fat/misterplex/misterplex.conf` in sync).
