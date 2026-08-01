# SHIP RUNBOOK — USER BUG #2 low-res player overlay (zero placeholders)

**Branch:** `w-osd-hires`  
**Tip:** run `git -C .worktrees/w-osd-hires rev-parse --short HEAD`  
**Binary:** `.worktrees/w-osd-hires/build/arm/misterplexd`  
**Artifact pair required on any device claim:** `md5sum` of deployed RBF + daemon.

## Do NOT use for verification
- **`tools/readback_overlay_text.py`** — PROVEN false positive: returns  
  `recovered='PAUSED' conf=0.5802` on a **blank bright panel with zero glyphs**  
  (parent execution). **Banned** for green claims on this bug.
- Framework OSD / pad-only paths — closed.

## What the fix does (ARM)
1. Canvas = DDR **coded bank 624×480** via `ddrFrameGeometryForFpgaPresent` (DECODE ignored).
2. FFmpeg scale+pad content **into** that bank (upscale **kept** — load-bearing).
3. `renderOverlay` / pause / idle paint chrome **after** that upscale at 624×480.
4. Fonts: h≥480 → 12×16@2; **240p-class h&lt;480 → 8×13@2**, panel clamped in-bounds.
5. **Vertical ceiling:** today FPGA may fetch only even store rows (240 unique).  
   w-fit-1 fitting lift to 480 unique. ARM already authors full 480 lines;  
   **no claim of pixel-perfect HDMI-native text** until parent confirms ceiling lifted  
   on glass (RBF md5 + grab). Post-fix: full 480 rows of HUD ink become visible.

## Host gates (coverage stated)
| Gate | What it inspects | Seen RED? |
|------|------------------|-----------|
| `test_overlay_raster_geometry_static.py` | `media_player.cpp` source: FpgaPresent, no PresentedSize(outW), Yuv renderYuv420p | **YES** — main → defects, `true rc=1` |
| `test_overlay_post_upscale` | Geometry 320→624; metrics present>content; real YUV ink runs | N/A unit math; fails if bank≠624 |
| `test_overlay_crispness_mutation` | mean |∇| on panel ink: bank paint vs content→NN; adaptive 1080/800/640/240 | **YES** — defect path grad=22.4 fails floor 30 (mutant rc=1); bank grad=38.0 passes (rc=0). **No OCR / no readback_overlay_text.py** |
| `test_overlay_post_upscale_red_main.sh` | meta: main must fail contract | **YES** prints RED_OK when main fails |

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-hires
python3 tests/unit/test_overlay_raster_geometry_static.py; echo "true rc=$?"
./build/test_overlay_post_upscale; echo "true rc=$?"
# Prove RED on main (expect printed defects and non-zero if you invert — see below)
python3 - <<'PY'
import re, subprocess, sys
src=subprocess.check_output(["git","show","main:arm/misterplexd/media_player.cpp"], text=True)
fails=[]
if "ddrFrameGeometryForFpgaPresent(outW_, outH_)" not in src: fails.append("no FpgaPresent")
if re.search(r"ddrFrameGeometryForPresentedSize\(\s*outW_\s*,\s*outH_\s*\)", src): fails.append("PresentedSize")
ro=re.search(r"auto\s+renderOverlay\s*=\s*\[\&\]\s*\(uint8_t\*\s*data\)\s*\{(.*?)\}\s*;", src, re.S)
y=re.search(r"case\s+RawVideoFormat::Yuv420p\s*:\s*(.*?)break\s*;", ro.group(1) if ro else "", re.S) if ro else None
if not y or "renderYuv420p" not in y.group(1): fails.append("Yuv break")
print("main_defects:", fails); sys.exit(1 if fails else 0)
PY
echo "main_contract true rc=$?"   # expect true rc=1
```

## Deploy (parent only)
```bash
# rebuild if needed
make -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-osd-hires arm-plexd; echo "true rc=$?"
md5sum .worktrees/w-osd-hires/build/arm/misterplexd
# deploy daemon ONLY (no RBF thrash unless pairing with w-fit ceiling RBF)
# record: RBF_MD5=… DAEMON_MD5=…
```

## Capture window for w-plextv-1 / parent
| Item | Value |
|------|--------|
| **UI state** | Playback **PAUSED** (not playing chrome flash) |
| **Hold** | **≥ 8 seconds** sticky pause (overlay does not fade while Paused) |
| **Ideal** | 10 s pause hold, single 1920×1080 (or 1280×720) still mid-window |
| **Log must show** | `pause overlay canvas=624x480 font=12x16 scale=2` + `authoring=624x480` and either `source=ini output=WxH` or `output=DEFAULT_ASSUMED` — **reject** `320x240` |
| **GEOM log** | `decode_target=624x480` with `arm_rescale=1` if DECODE=320x240 |
| **SEE** | Bottom transport panel, PAUSED label, timeline — glyphs should match **12×16 cell @2** on bank (advance ~26 bank-px), **not** 8×13 content-tier mush |
| **Do not score with** | `readback_overlay_text.py` |
| **After w-fit ceiling RBF** | Re-grab same pause; vertical glyph edges should use odd+even rows (parent solid-field card must no longer invert) |

```bash
# HDMI still (parent, free /dev/video0 first)
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 1 -y /tmp/pause_overlay.png; echo "true rc=$?"
```
