PARENT — MS2109 instrument-floor capture (agent does not touch device)

Fixture: exact source cadence fps=24.0 n_source=240
mp4=cadence_24.000.mp4  static=static_frame.png
ffmpeg_rc=0

PRE_REGISTER floor expectation (locked):
  Host plays exact 24.0 fps CFR into display → HDMI → MS2109 → ffmpeg PNG burst.
  After warmup_skip=15, content-aware holds should cluster on healthy mass for
  capture_fps/source_fps (30/24 → holds {1,2}). Floor TAIL (p95/p99/max,
  outlier_count) is the instrument envelope. Device claims require device tail
  exceeding this floor by margin (see --floor-json).

A) CADENCE FLOOR (known-exact motion through grabber path)
  1. fuser -v /dev/video0   # must be free
  2. On the display that feeds the MS2109 HDMI input:
       mpv --fs --no-osc --loop=no cadence_24.000.mp4
     (or ffplay -fs cadence_24.000.mp4)
  3. While playing:
       mkdir -p floor_cap_cadence
       ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080          -i /dev/video0 -frames:v 120 -y floor_cap_cadence/f_%03d.png
       echo "true rc=$?"
  4. Score:
       python3 tools/glass_motion_judder.py floor_cap_cadence --role instrument_floor          --source-fps 24.0 --source-fps-src caller_supplied_measured          --capture-fps 30 --capture-fps-src caller_supplied          --label floor_cadence_host --json > floor_cadence.json
       python3 tools/glass_motion_judder.py floor_cap_cadence --role instrument_floor          --source-fps 24.0 --source-fps-src caller_supplied_measured          --capture-fps 30 --capture-fps-src caller_supplied          --label floor_cadence_host; echo "true rc=$?"

B) STATIC FLOOR (grabber duplication/noise only — no source motion)
  1. Pause on one frame or display static_frame.png fullscreen.
  2. mkdir -p floor_cap_static
     ffmpeg -v error -f v4l2 -input_format mjpeg -video_size 1920x1080        -i /dev/video0 -frames:v 90 -y floor_cap_static/f_%03d.png
     echo "true rc=$?"
  3. Score (expect near-zero changes; UNSCORED-or-floor with holds≈all-one-run):
       python3 tools/glass_motion_judder.py floor_cap_static --role instrument_floor          --source-fps 24.0 --source-fps-src caller_supplied_measured          --capture-fps 30 --capture-fps-src caller_supplied          --label floor_static; echo "true rc=$?"

C) DEVICE (only AFTER floor JSON exists)
       python3 tools/glass_motion_judder.py /tmp/cap480b --role device_under_test          --floor-json floor_cadence.json          --source-fps 24 --source-fps-src caller_supplied_measured          --capture-fps 30 --capture-fps-src caller_supplied; echo "true rc=$?"

BEAT (24.000 @ 30.000): commensurate 4:5, pattern period 5 cap frames = 166.667 ms.
Discrete IFI on grid: 33.333 and 66.667 ms (mean 41.667). Reject T_cap/sqrt(12).

AMENDMENT (parent 2026-08-01): host mpv → grabber CANNOT work on this rig.
Grabber HDMI is cabled to DE10-Nano; host HDMI-A-1 is disconnected.
Content-dup floor requires USER physical cable move, or a joint 60 Hz
frame-stamp fixture on device (not pure instrument floor).
Use tools/glass_capture_timing_floor.py on static-logo pts for timing-only floor.
