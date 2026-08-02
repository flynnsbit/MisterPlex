# PARENT — rk=9 / rk=27 @ 720p60 capture + score (w-instr)

**Branch tip:** see git  
**device_attributable=False** until content-dup floor (cable move). Timing floor attached only as timing envelope; does **not** green-light content claims.

## Pre-register LOCKED before your capture (24.000 src @ 60 cap)

```
source_fps=24.000 [caller_supplied_measured]   # PMS frameRate metadata
capture_fps=60     [measured]                  # v4l2 1280x720@60 confirmed
ratio=5/2 commensurate=True
ideal_hold=2.5 [derived_cap_over_src]
healthy_hold_mass={2,3}
hold_outlier_min=4          # first hold ABOVE healthy mass (ceil(2.5)+1)
max_hold_fail=6
FAIL if: outlier_count>=3 OR frac_ge_outlier>=0.05 OR frac_outside_healthy>=0.05 OR max_hold>=6
```

### ~13 fps delivered — TRUE POSITIVE (threshold NOT retuned to delivered rate)

If display advances ~13 content frames/s against 60 Hz capture:
- mean hold ≈ 60/13 ≈ **4.62**
- mass around **{4,5}**
- healthy is {2,3} → **frac_outside_healthy → 1.0** → **JUDDER_FAIL rc=2**

**Decision (now, before capture):** this is a **true positive** for “motion not at source rate.”  
We score against **source_fps=24 measured from PMS**, not against daemon vfps.  
Retuning `outlier_min` to delivered rate would **normalise away the user’s bug**. Do not do that.

Self-test proof:
- pure hold=4 (≈15 fps) → JUDDER_FAIL  
- mix {4,5} (≈13 fps) → JUDDER_FAIL  
- healthy {2,3} → JUDDER_OK  

## Blindness pre-check (seconds, before full score)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-instr-provenance

# After capture:
python3 tools/glass_motion_judder.py /tmp/cap_rk9_720p60 --precheck-only --warmup-skip 15
echo "true rc=$?"
# rc=0 PRECHECK_SUITABLE — proceed to full score
# rc=77 PRECHECK_BLIND — black/static (rk=6 class); do NOT treat as judder PASS/FAIL
```

## Exact capture (parent owns device + grabber)

```bash
fuser -v /dev/video0   # must be free

# --- rk=9 Big Buck Bunny 624x352 h264 24.000 ---
mkdir -p /tmp/cap_rk9_720p60
# start cast/play rk=9 on device first, wait until past any spinner
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
  -i /dev/video0 -frames:v 300 -y /tmp/cap_rk9_720p60/f_%03d.png
echo "true rc=$?"

# --- rk=27 Bank480 FullBleed 624x480 24.000 ---
mkdir -p /tmp/cap_rk27_720p60
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
  -i /dev/video0 -frames:v 300 -y /tmp/cap_rk27_720p60/f_%03d.png
echo "true rc=$?"
```

300 frames @ 60 fps ≈ 5 s content after warm-up 15 ≈ 285 scored → plenty of holds.

## Exact score invocations

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-instr-provenance
FLOOR=./.agent-work/w-instr/floor_capture_timing.json

# Precheck first (cheap)
python3 tools/glass_motion_judder.py /tmp/cap_rk9_720p60 --precheck-only --warmup-skip 15
echo "precheck_rk9 true rc=$?"

python3 tools/glass_motion_judder.py /tmp/cap_rk9_720p60 --warmup-skip 15 \
  --role device_under_test \
  --floor-json "$FLOOR" \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 60 --capture-fps-src measured \
  --label rk9_bbb_720p60
echo "score_rk9 true rc=$?"

python3 tools/glass_motion_judder.py /tmp/cap_rk27_720p60 --precheck-only --warmup-skip 15
echo "precheck_rk27 true rc=$?"

python3 tools/glass_motion_judder.py /tmp/cap_rk27_720p60 --warmup-skip 15 \
  --role device_under_test \
  --floor-json "$FLOOR" \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 60 --capture-fps-src measured \
  --label rk27_bank480_720p60
echo "score_rk27 true rc=$?"
```

**Expect on labels:**
- `capture_fps=60 [measured]` `source_fps=24 [caller_supplied_measured]`
- `healthy_mass={2,3}` `outlier_min=4`
- `device_attributable=False` (timing floor only; content-dup still open)
- If rk=9 is really ~13 fps glass: `JUDDER_FAIL` with mass near {4,5}, frac_outside_healthy high
- If rk=27 healthy 24@60: hold_hist mass on {2,3}, outliers≈0 → JUDDER_OK pixels (still not product-attributable)

## Optional JSON for your logs
Add `--json > /tmp/rk9_judder.json` on a second run if you want machine-readable tails.

## What not to do
- Do not use rk=6/rk=1 for judder (precheck will rc=77).
- Do not set source-fps from daemon vfps.
- Do not pass timing floor as proof of content health.
