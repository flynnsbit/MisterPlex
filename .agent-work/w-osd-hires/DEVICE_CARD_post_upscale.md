# Device card — post-upscale overlay (parent runs)

## Build / deploy (parent)
```bash
# From w-osd-hires worktree after merge/deploy of this tip
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-hires
make -C arm/misterplexd 2>/dev/null || make arm-plexd
# deploy daemon only (parent's usual path), e.g.:
# scripts/deploy_misterplexd.sh
```

## Host gates before device (must be green)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-hires
make "$(pwd)/build/test_overlay_post_upscale" && ./build/test_overlay_post_upscale; echo "true rc=$?"
python3 tests/unit/test_overlay_raster_geometry_static.py; echo "true rc=$?"
python3 tests/unit/test_unit_rollcall.py; echo "true rc=$?"
```

## Get HUD on screen and hold it
1. Cast local PMS item (parent): `files/parent_cast_local.sh` or Playwright play.
2. Confirm playback presents: companion `/resources` 200, presents increasing.
3. **Pause** via Plex Web UI (or companion pause API if used in lab).
4. HUD is sticky while paused (`PlaybackOverlayState::Paused` alpha does not time out).
5. Capture within a few seconds of pause (no need to rush — sticky).

```bash
# HDMI grab (parent exclusive /dev/video0)
fuser -v /dev/video0 2>/dev/null || true
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 1 -y /tmp/pause_overlay.png; echo "true rc=$?"
```

## Pre-registered predictions (VIEWED PIXELS decide)
| # | Prediction | PASS look | FAIL look |
|---|------------|-----------|-----------|
| P1 | Daemon log on pause includes `pause overlay canvas=624x480` (not 320x240) | greppable 624x480 | canvas=320x240 |
| P2 | Log includes `font=12x16 scale=2` at that canvas | 12x16 | 8x13 at 624 (wrong tier) |
| P3 | Log GEOM line: `decode_target=624x480` with `arm_rescale=1` when DECODE=320x240 | rescale 1, target 624 | target 320 |
| P4 | Pause panel text legible on grab; glyph cells coarser than pure 320-upscale mush | sharp-ish 12x16@2 on bank | blocky 8x13@2 blown from 320 |
| P5 | Idle chevron still OK after pause/resume/stop | orange chevron | freeze/blank |

## Log greps (on device via parent ssh)
```bash
# after pause
grep -E 'pause overlay canvas=|media: GEOM ' /path/to/daemon.log | tail -20
```

## Out of scope this card
- True 1920×1440 native HUD (needs post-ascal plane RBF — not this ARM-only change)
- sys/osd.v framework OSD (closed negative)
