# PARENT CARD — capture-timing floor folded + content-dup + rate (w-instr)

**Branch:** `w-instr-provenance` (push tip below)  
**Holds the line:** content hold/IFI stays `device_attributable=False` until content-dup floor exists.

## 1. Capture-timing floor — FOLDED (`role=instrument_floor_capture_timing`)

Tool: `tools/glass_capture_timing_floor.py`  
Input: parent `/tmp/pts_static.txt` (static logo, pts from showinfo)

```
n_intervals=134 [measured]  warmup_skip_frames=15 [DEFAULT_ASSUMED]
leading_gap_ms=204.114 discarded (pts 0 → first real frame)
interval_ms min=31.851 p50=32.067 p95=36.023 p99=36.054 max=36.078
mean=33.312 stdev=1.869  hist≈{32.0:90, 36.0:44}
outliers_gt_1.5x_median=0  outliers_gt_2x_median=0
max_dev_from_median_ms=4.011
implied_capture_fps=30.0189 [derived_1000_over_mean_interval]
VERDICT=FLOOR_CAPTURE_TIMING_OK  true rc=0
device_attributable=False
content_duplication_floor=UNMEASURED
gates_content_hold_ifi=False
```

**Scope note (do not overstate):** bounds **delivery timing only**. Rules out grabber *timestamp* drops as the ~50 ms story. Does **not** bound content duplication on regular timestamps.

**Hard gate:** this JSON must **not** green-light content judder attribution. Proven:

```bash
python3 tools/glass_motion_judder.py /tmp/cap480b --floor-json .agent-work/w-instr/floor_capture_timing.json ...
# → device_attributable=False  attribution_note=floor-json is capture-timing only...
# VERDICT may still print JUDDER_OK on pixels — that is measured pattern, NOT product claim
```

```bash
python3 tools/glass_capture_timing_floor.py /tmp/pts_static.txt --label parent_static_logo
echo "true rc=$?"
python3 tools/glass_capture_timing_floor.py /tmp/pts_static.txt --json \
  > .agent-work/w-instr/floor_capture_timing.json
```

## 2. Content-duplication floor without re-cabling — VERDICT

**Not separable with the current rig.** Plain answer:

| Approach | Why it fails without host→grabber HDMI |
|---|---|
| Host `mpv` cadence fixture | Grabber HDMI is on **DE10 only**; host `card1-HDMI-A-1=disconnected`. Capture would silently be device (your blocker). |
| Static logo content path | Measures false-change noise, not forced dup under motion. |
| TREK24 counter holds | Joint device+grabber+display 3:2; expected mass known, **excess not assignable** to grabber vs device. |
| “Arithmetic 60→30 must dup” | True, but without unique **per-HDMI-frame** stamps we cannot count which frames the grabber kept. |

**Acceptable path A — user cable move (preferred pure floor):**  
Host display → MS2109 HDMI in; play `floor_fixture/cadence_24.000.mp4`; score `--role instrument_floor`. That is the only pure instrument content-dup floor.

**Acceptable path B — joint fixture (still not pure grabber):**  
Device renders a **unique stamp every 60 Hz output frame** (not once per 24 fps source). Then capture at 30 fps and count kept stamps vs arithmetically forced keep rate. Residual after subtracting forced dups is joint device+grabber — better than nothing, **not** a pure instrument floor. Needs w-asset/device work.

**I will not fudge a content-dup floor from timing regularity.**

## 3. Capture rate — measured capability (v4l2, not assumed)

Source: `v4l2-ctl --device=/dev/video0 --list-formats-ext` → `.agent-work/w-instr/ms2109_v4l2_formats.txt`

| Mode | Max fps (MJPEG) | Notes |
|---|---|---|
| **1920×1080** | **30** (also 25, 20, 10, 5) | **No 60 p at 1080p** over this stick |
| **1280×720** | **60** (also 50, 30, …) | 60 p available if resolution trade OK |
| YUYV 1080p | 5 fps only | useless for motion |

### Recommendation (highest leverage)

1. **Primary experiment: 1080p @ 25 fps** (`-framerate 25` / v4l2 interval 25).  
   - Beat vs 24.000: ratio **25/24**, pattern period **1000 ms** (25 cap / 24 src).  
   - `commensurate=True` still (rational), but **ideal hold ≈ 1.0417** → healthy mass almost all **hold=1**, rare hold=2 every ~24 source frames.  
   - Drop signature (hold≥3 / IFI≥120 ms) separates from healthy much more cleanly than 30 fps 5/4 bimodal {1,2}.  
   - Keeps full HD for OCR/colour instruments.

2. **Secondary: 720p @ 60 fps** if you accept resolution drop.  
   - ratio **60/24=5/2**, ideal hold=2.5, healthy mass **{2,3}** — classic 3:2 visible directly.  
   - Drop → hold≥5 (IFI≥83 ms at 60) clearer tail.  
   - 1080p60 **not offered** by this MS2109.

3. **Keep 30 fps** only as legacy comparable to existing bursts; beat analysis already solid there.

```bash
# 1080p25 content burst (parent)
fuser -v /dev/video0
mkdir -p /tmp/cap480b_25
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 25 \
  -i /dev/video0 -frames:v 120 -y /tmp/cap480b_25/f_%03d.png
echo "true rc=$?"

cd .worktrees/w-instr-provenance
python3 tools/glass_motion_judder.py /tmp/cap480b_25 --warmup-skip 15 \
  --role device_under_test \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 25 --capture-fps-src caller_supplied_measured \
  --label 480p_cap25; echo "true rc=$?"
# still device_attributable=False until content-dup floor
```

```bash
# Optional 720p60
mkdir -p /tmp/cap_720p60
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
  -i /dev/video0 -frames:v 180 -y /tmp/cap_720p60/f_%03d.png
echo "true rc=$?"
python3 tools/glass_motion_judder.py /tmp/cap_720p60 --warmup-skip 15 \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 60 --capture-fps-src caller_supplied_measured \
  --label cap720p60; echo "true rc=$?"
```

## 4. Device run with `--floor-json` — what I will and will not claim

Timing floor JSON is saved. If you pass it:

```bash
cd .worktrees/w-instr-provenance
python3 tools/glass_motion_judder.py /tmp/cap480b --warmup-skip 15 \
  --role device_under_test \
  --floor-json .agent-work/w-instr/floor_capture_timing.json \
  --source-fps 24 --source-fps-src caller_supplied_measured \
  --capture-fps 30 --capture-fps-src caller_supplied_measured \
  --label 480p; echo "true rc=$?"
```

**Expected:** pixel hist may be JUDDER_OK; **`device_attributable=False`** because floor is timing-only. That is correct.  
There is **no** content `--floor-json` I can honestly give you until cable move or joint 60 Hz stamp fixture.

## 5. Host mpv floor procedure — AMENDED

Previous PASTE that played host mpv into grabber is **void on this rig** (DE10 cabled). README updated in spirit: requires **user physical HDMI move**. Do not run as if it were a floor.

## 6. Self-test
```bash
python3 tools/glass_motion_judder.py --self-test; echo "true rc=$?"
python3 tools/glass_capture_timing_floor.py /tmp/pts_static.txt; echo "true rc=$?"
```
