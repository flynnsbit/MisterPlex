# Parent commands — primary glass instruments (ARM frames_done VOID)

Deployed RBF c5382bee: `frames_done` is bank_vsync_count. Glass is sole skip evidence.

## 0) Host gates (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex
python3 tools/glass_hold_skip.py --self-test; echo "true rc=$?"
python3 tools/hdmi_vstore_discriminate.py --self-test; echo "true rc=$?"
python3 scripts/gen_vstore_ceiling_fixture.py; echo "true rc=$?"
```

## 1) Definitive hold+skip on banked p60 (no device)

```bash
python3 tools/glass_hold_skip.py /tmp/p60/png \
  --templates /tmp/p60/T60.pkl --pts /tmp/p60/pts.csv \
  --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720 --progress
true_rc=$?; echo "true rc=$true_rc"
# Expect: UNSCORED rc=77 (ERROR19 max_iv=21>=16.67); hold hist + median/trim printed;
# genuine=0; margin_unresolved may list 5578.
```

## 2) New capture for hold/skip (you own /dev/video0)

```bash
# Prefer 720p60 for margin; 1080p30 is ERROR18-class refuse.
mkdir -p /tmp/glass_hold_cap/png
# 720p60 example (if grabber mode set):
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
  -i /dev/video0 -t 90 -c copy /tmp/glass_hold_cap/cap.mkv
ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 \
  /tmp/glass_hold_cap/cap.mkv > /tmp/glass_hold_cap/pts.csv
ffmpeg -v error -i /tmp/glass_hold_cap/cap.mkv /tmp/glass_hold_cap/png/f_%05d.png
# drop first ~15 warm-up in tool:
python3 tools/glass_hold_skip.py /tmp/glass_hold_cap/png \
  --templates /tmp/p60/T60.pkl --pts /tmp/glass_hold_cap/pts.csv \
  --source-fps 24 --capture-fps 60 --refresh-hz 60 --force-mode 720 \
  --warmup-skip 15 --progress
true_rc=$?; echo "true rc=$true_rc"
```

Pre-register (tool prints first): ideal hold=cap/src; ge4 bands; genuine_frac_fail=0.005;
min_hold=1000/60; UNSCORED if margin violated.

## 3) B2 / ceiling BEFORE bank (do this on current core NOW)

```bash
# Package fixtures (w-asset480 may wrap into H.264 cast asset):
python3 scripts/gen_vstore_ceiling_fixture.py
# After casting odd_only / even_only / full on device, capture stills:
# fuser -v /dev/video0   # must be free
ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 20 -y /tmp/vstore_before/f_%02d.png
# Score (n_low_phases — NOT period max/min):
python3 tools/hdmi_vstore_discriminate.py /tmp/vstore_before/f_*.png --odd-even
true_rc=$?; echo "true rc=$true_rc"
```

PRE-REGISTER before/after:
- BEFORE odd_only: odd_over_even << 1; low-phase class 240 (n_low>=2 at p=3)
- AFTER fix: odd_only odd_over_even rises; class may leave 240
- UNSCORED on idle/black — never pass

Bank `/tmp/vstore_before` (or repo path you choose) before w-fit-1 deploys new RBF.

## 4) OCR fixture still works for skip when margin OK

`tools/glass_template_skip.py` remains the decoder; `glass_hold_skip.py` is the
parent-facing report (hold hist + robust intervals + verdict).
