# HDMI lipsync measurement (true A/V offset)

**Why:** Parent settled video loss at **0.070%** (1/1430). Remaining user-visible
defect candidate is **audio sync**. Daemon `av_drift_ms` is self-labelled
`av_drift_role=servo_error_not_lipsync` and is pinned by `AV_PRESENT_LEAD_MS`.
Only grabber-side flash↔beep offset is ground truth.

**Agent does not touch the device.** Parent captures and scores.

---

## Fixture (required)

| Asset | Usable for lipsync? |
|-------|---------------------|
| **Glass OCRProof** (`ratingKey=13`, `G n=…`) | **NO** — continuous/loud audio, no discrete 1 kHz onset at integer seconds; tool cannot pair flash↔beep |
| **MiSTerPlex Soak 480p 24fps (2026)** (`ratingKey=8`, 624×480 @ **24.000**, TREK24) | **YES** — white flash ~2 frames + 50 ms 1 kHz beep every 1.0 s (file-aligned) |
| `assets/avsync/sync_24fps_blip.mp4` | YES (short product 320×240) — unit-test corpus |
| `scripts/gen_avsync_blip.py --only soak480-ramp` | YES preferred for sub-frame onset (centered ramp) |

**w-asset480:** keep ratingKey=8 (or register soak480-ramp) in Plex. Spec:
- 624×480, `r_frame_rate=24/1` (**not** 23.976)
- flash+beep every **1.0 s**, simultaneous at integer file time
- counter every frame (already true for gen_avsync_blip)
- AAC 48 kHz stereo OK (daemon path); instrument recovers PCM from capture

Verify before soak:
```bash
ffprobe -v error -show_entries stream=width,height,r_frame_rate,nb_frames,duration,codec_type,sample_rate \
  -of default=nw=1 "/path/to/soak480.mp4"
# expect: 624 480 24/1 8640 360.000 video + aac 48000
```

---

## Tool

`tools/avsync_measure_hdmi.py`

**Sign:** `offset_ms = (t_audio_onset − t_video_flash) × 1000`
- **positive** = audio LATE (lags video)
- **negative** = audio EARLY (leads video)

**Capture:** ONE ffmpeg, ONE Matroska (MJPEG + pcm_s16le), both inputs
`-use_wallclock_as_timestamps 1`, plus `-copyts -start_at_zero`.
Shared wall clock at open — without that, dual-input first-packet zeroing
creates a false ~117 ms mode (RETRACTED OLD-argv).

Default grabber: `/dev/video0` MJPG **1920×1080@30** (parent-measured max at
1080p; 720p@60 is optional via `--video-size 1280x720 --cap-fps 60` only if
`v4l2-ctl` lists it). ALSA `hw:0,0` (MS2109). Warm-up discard default **20** frames.

**Absolute** median without known-zero cal into the grabber is always
`tag=raw_uncalibrated`. **Same-rig Δ** (LEAD A vs B) cancels fixed grabber skew B.

---

## Red-before-green (host, no device) — MANDATORY

```bash
bash tests/unit/test_avsync_measure_hdmi.sh; echo "true rc=$?"
# expect AVSYNC_MEASURE_HDMI_OK, true rc=0

# Explicit 100 ms defect recovery (adelay):
WORK=.agent-work/w-avsync/prove100
mkdir -p "$WORK"
FIX=assets/avsync/sync_24fps_blip.mp4
ffmpeg -hide_banner -loglevel error -y -i "$FIX" -t 12 \
  -c:v libx264 -pix_fmt yuv420p -c:a pcm_s16le "$WORK/base0.mkv"
ffmpeg -hide_banner -loglevel error -y -i "$FIX" -t 12 \
  -c:v libx264 -pix_fmt yuv420p -af "aresample=48000,adelay=100|100" \
  -c:a pcm_s16le "$WORK/d100.mkv"
python3 tools/avsync_measure_hdmi.py --input "$WORK/base0.mkv" \
  --out "$WORK/r0" --label base0 --tol-ms 42; echo "base0 true rc=$?"
python3 tools/avsync_measure_hdmi.py --input "$WORK/d100.mkv" \
  --out "$WORK/r100" --label d100 --tol-ms 42; echo "d100 true rc=$?"
```

**Banked evidence (this lane, direct rc):**

| Case | median_offset_ms_raw | true rc | notes |
|------|---------------------:|--------:|-------|
| aligned 0 ms | **0.0000** | **0** | PASS |
| adelay **+100 ms** | **99.0000** | **2** | FAIL tol=42; recovers defect |
| unit p250 itsoffset | 249.0 | 2 | |
| unit m200 | −208.3 | 2 | |
| unit silent / static | — | **77** | UNSCORED ≠ pass |
| adelay ladder RMSE | **0.95 ms** | 0 | 0…150 ms steps |

An instrument that only ever reports ~0 is not evidence. This one reports **99 ms**
when 100 ms is injected.

---

## Parent live soak (you run)

### A. Capture while MiSTer plays soak480 blip (ratingKey=8)

```bash
# devices (parent-measured on this host)
arecord -l                    # expect MS2109 → hw:CARD,0
v4l2-ctl -d /dev/video0 --list-formats-ext | head -40

OUT=/path/you/choose/avsync_live_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"

# Prefer tool-owned capture (wallclock+copyts binding):
python3 tools/avsync_measure_hdmi.py \
  --duration 60 \
  --video-dev /dev/video0 \
  --audio-dev hw:0,0 \
  --video-size 1920x1080 \
  --cap-fps 30 \
  --warmup-frames 20 \
  --tol-ms 42 \
  --out "$OUT" --label live60 \
  --json-out "$OUT/live60_report.json"
echo "true rc=$?"

# Or manual ONE-process capture then analyse:
# ffmpeg -hide_banner -y \
#   -use_wallclock_as_timestamps 1 -f v4l2 -input_format mjpeg \
#     -video_size 1920x1080 -framerate 30 -i /dev/video0 \
#   -use_wallclock_as_timestamps 1 -f alsa -ac 2 -ar 48000 -i hw:0,0 \
#   -c:v copy -c:a pcm_s16le -copyts -start_at_zero -t 60 "$OUT/cap.mkv"
# python3 tools/avsync_measure_hdmi.py --input "$OUT/cap.mkv" \
#   --warmup-frames 20 --tol-ms 42 --out "$OUT" --label file60
```

Report: **distribution** (`min/median/mean/stdev/max`, `n_pairs`, early/late medians),
not a single number. `rc=77` = could-not-measure (never PASS).

### B. Device falsifier — LEAD delta must move MEASURED offset

Env override preferred (conf is user-owned; do not silently normalise):

```bash
CONF=/media/fat/misterplex/misterplex.conf
cp -a "$CONF" "/media/fat/misterplex/misterplex.conf.bak_lead_$(date +%Y%m%d%H%M%S)"

# Arm A
MISTERPLEX_AV_PRESENT_LEAD_MS=40  # restart daemon; play soak480 ≥70 s wall
# capture with tool → median_A (raw_uncalibrated OK)

# Arm B (conf bytes must stay identical)
MISTERPLEX_AV_PRESENT_LEAD_MS=20
# capture → median_B

cmp -s "$BACKUP" "$CONF" && echo CONF_UNCHANGED_OK
```

| Check | PASS | FAIL |
|-------|------|------|
| daemon setpoint A/B | −40 / −20 | else |
| **Δmedian = median_B − median_A** | **∈ [+12, +28] ms** (expect ≈ +20) | outside |
| conf cmp | identical | any write |
| claiming absolute lipsync from one arm | **forbidden** | — |

If LEAD 40→20 and grabber median does **not** move ≈+20 ms: either the knob is
dead on the present path, or capture fingerprint changed (do not pool).

**Prediction (pre-register):** lowering lead advances video presents relative to
audio → audio appears **later** vs flash → **positive** Δoffset_ms ≈ +Δlead.

---

## What this does / does not prove

| Proves | Does not prove |
|--------|----------------|
| Real flash↔beep offset on HDMI capture timebase | That `av_drift_ms` is lipsync |
| Instrument sees injected defects (100 ms → 99 ms) | Absolute device lipsync without known-zero cal |
| LEAD delta moves true offset (if B cancels) | Video frame-loss story (already settled 0.07%) |

fps for this RCA: **24.000** only. Never print 23.976 as a measurement.
