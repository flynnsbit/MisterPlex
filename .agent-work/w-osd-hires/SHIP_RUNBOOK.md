# SHIP RUNBOOK — USER BUG #2 low-res player overlay
**Branch:** w-osd-hires @ 6b1b68c7+  
**Binary:** `build/arm/misterplexd` md5 `40170b99801bff7c743407df23cb424a` (rebuild if tip moves)  
**Parent deploys + HDMI only.**

## What shipped (ARM-only)
HUD composites **after** FFmpeg scale into DDR coded bank **624×480**, not at DECODE 320×240.
- `ddrFrameGeometryForFpgaPresent` ignores DECODE → always plex480p bank
- `renderOverlay` → `renderYuv420p(data, rawW, rawH)` with rawW/H = coded bank
- Pause/idle same bank via `plex480pDdrFrameGeometry()`
- Metrics: 12×16@2 at h≥480; **8×13@2 at 240p-class** (legible tier)
- **Not claimed:** pixel-perfect vs HDMI video_mode (ascal) or full vertical res (w-fit 240-row ceiling)

## Host proof (parent or CI)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-hires

# GREEN on tip
python3 tests/unit/test_overlay_raster_geometry_static.py; echo "true rc=$?"
./build/test_overlay_post_upscale; echo "true rc=$?"
bash tests/unit/test_overlay_post_upscale_red_main.sh; echo "true rc=$?"   # expects RED_OK rc=0
python3 tests/unit/test_unit_rollcall.py; echo "true rc=$?"
```

**RED-before-green (captured):**
| Subject | Result |
|---------|--------|
| main media_player | contract FAIL rc=1 (PresentedSize(outW)+Yuv empty break) |
| tip media_player | static OK rc=0; post_upscale OK rc=0 |

## Deploy daemon (parent)
```bash
# use lab deploy script; do NOT thrash RBF
# example:
# scp build/arm/misterplexd root@192.168.1.183:/media/fat/misterplex/
# then parent soft-restart daemon (one menu bounce if needed)
```

## SEE on device after pause
1. Cast: `files/parent_cast_local.sh` (or Playwright play)
2. Pause via Plex Web UI — HUD **sticky** while paused
3. Expect daemon log:
   - `pause overlay canvas=624x480 font=12x16 scale=2`  (**not** 320x240)
   - `media: GEOM ... decode_target=624x480 arm_rescale=1` when DECODE=320x240
4. HDMI grab:
```bash
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 1 -y /tmp/pause_overlay.png; echo "true rc=$?"
```
5. VIEW: PAUSED panel + timeline; text should look like **12×16@2 on 624 bank** (clearer than 8×13@2 from 320 content), **not** mushy double-upscale from content-tier HUD.  
   Vertical may still show even-row softness until w-fit lifts 240 ceiling — do not score as 1080p-native.

## Closed approaches (do not reopen)
- sys/osd.v framework OSD
- pad-only / no ARM upscale
