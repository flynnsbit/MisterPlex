# MiSTerPlex v0.4.0

Multi-resolution cast release: **240p / 480p / 720p**, live PMS encoder match, DDR present always on.

## Highlights

- **Content resolution labels:** OSD and product profiles use **240p / 480p / 720p** (CONF_STR v8 `O[5:4]`). Internal banks remain 320×240, 640×480 (624 coded), 1280×720.
- **Live PMS match:** Changing content resolution retargets the Plex universal weak ladder (`videoResolution` + bitrate/profile) and restarts the session at the same playhead. FFmpeg always FOAR+pads network/PMS streams to the DECODE bank (PMS often returns a smaller coded size than requested — never trust `videoResolution` alone). Local identity play-files may skip scale.
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
