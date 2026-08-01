# HDMI lipsync measurement (true A/V offset)

**Why:** Frame loss is **bounded, not measured** (parent ERROR 18/19 withdrawn —
grabber sampling margin killed skip claims). Measured video defect is **judder**
(adjacent holds equal ~30% where 3:2 predicts 0%). A mean-only A/V offset can
false-PASS while instantaneous timing wanders. Daemon `av_drift_ms` is
self-labelled `av_drift_role=servo_error_not_lipsync` and pinned by
`AV_PRESENT_LEAD_MS`. **Only grabber flash↔beep offset is lipsync ground truth.**

**Agent does not touch the device.** Parent captures and scores.

---

## Fixture (required)

| Asset | Usable for lipsync? |
|-------|---------------------|
| **Glass OCRProof** (`ratingKey=13`, `G n=…`) | **NO** — no discrete 1 kHz onset at integer seconds |
| **MiSTerPlex Soak 480p 24fps** (`ratingKey=8`, 624×480 @ **24.000**) | **YES** — white flash ~2 frames + 50 ms 1 kHz beep / 1.0 s |
| `assets/avsync/sync_24fps_blip.mp4` | YES — unit corpus |
| `scripts/gen_avsync_blip.py --only soak480-ramp` | YES preferred (sub-frame onset) |
| Audio ID (`docs/audio_frame_id_contract.md`, `tools/audio_frame_id.py`) | Self-check FSK index+checksum; soak480 bare beep = ID **NO-DATA** not FAIL |

fps for this RCA: **24.000 only** (`nb_frames/duration`). Never 23.976 (ERROR 17).

---

## Tool

`tools/avsync_measure_hdmi.py`  
Soak wrapper (CPU + measure): `tools/avsync_lipsync_soak.sh`  
ARM CPU sampler: `tools/avsync_sample_arm_cpu.sh`  
Audio ID contract: `tools/audio_frame_id.py` + `docs/audio_frame_id_contract.md`

### Sign
`offset_ms = (t_audio_onset − t_video_flash) × 1000`
- **positive** = audio LATE (lags video)
- **negative** = audio EARLY (leads video)

### Capture
ONE ffmpeg, ONE Matroska (MJPEG + pcm_s16le), both inputs
`-use_wallclock_as_timestamps 1`, plus `-copyts -start_at_zero`.
Without that, dual-input first-packet zeroing creates a false ~117 ms mode
(RETRACTED OLD-argv).

Default: `/dev/video0` MJPG **1920×1080@30** (1080p max), ALSA `hw:0,0`,
warmup discard **20** frames. SPAN-LOCAL rates only (first ~12–15 frames ~32 ms).

### What every report MUST include
- **Time series** of per-marker offsets (`*_offset_timeseries.csv` + stdout)
- **Distribution:** min / p05 / median / mean / p95 / max / IQR / stdev
- **`timing_class`:** `STABLE` | `MONOTONIC_DRIFT` | `WANDER` | `MARGIN_INADEQUATE`
- **`residual_rms_ms`** after linear detrend (wander metric)
- **`margin_verdict`** — refuses score when event < 2 capture samples (ERROR 19)
- **`arm_cpu_pct`** when soak wrapper supplies `--cpu-pct-json` (else NO-DATA)

Absolute median without known-zero cal = `tag=raw_uncalibrated`. Same-rig Δ
(LEAD A vs B) cancels fixed grabber skew B.

### Return codes (distinct — never collapse)

| rc | VERDICT | Meaning |
|----|---------|---------|
| 0 | PASS | offset in tol AND STABLE (not drift/wander) |
| 2 | OFFSET_FAIL | \|median\| > tol (path/device level) |
| 3 | INSTRUMENT_BROKEN | capture/tool broken |
| 4 | DRIFT_FAIL | monotonic clock-rate mismatch |
| 5 | WANDER_FAIL | high residual after detrend (mean may still be OK) |
| 6 | FIXTURE_FAIL | self-check audio/video ID failed when required |
| 77 | UNSCORED / MARGIN_INADEQUATE / REFUSE_DEFAULT_ASSUMED | **never a pass** |

Unlike `glass_template_skip.py` (rc=2 shared by skip vs instrument), each class
has its own rc **and** a `VERDICT=` string.

### Sampling margin
- Video sample: capture frame period (measured median PTS Δ)
- Audio sample: 48 kHz; Goertzel win ~20 ms; beep must cover ≥2 windows
- Flash must cover **≥2 capture frames** (discrete `flash_hold_frames_median`)
- ERROR 19 class (1-refresh hold @ 60 fps) → `VERDICT=MARGIN_INADEQUATE rc=77`

---

## Red-before-green (host, no device) — MANDATORY

```bash
bash tests/unit/test_avsync_measure_hdmi.sh; echo "true rc=$?"
# expect AVSYNC_MEASURE_HDMI_OK, true rc=0

python3 tools/avsync_measure_hdmi.py --self-test; echo "true rc=$?"
python3 tools/audio_frame_id.py --self-test 2>/dev/null || bash tests/unit/test_audio_frame_id.sh; echo "true rc=$?"

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

**Banked evidence (direct rc):**

| Case | median_offset_ms_raw | timing_class | true rc |
|------|---------------------:|--------------|--------:|
| aligned 0 ms | **0.0000** | STABLE | **0** |
| adelay **+100 ms** | **99.0000** | STABLE | **2** OFFSET_FAIL |
| unit ladder RMSE | **0.95 ms** | — | 0 |
| silent / static | — | — | **77** |

---

## Parent live soak (you run)

### Preferred one-shot

Device must already be playing soak480 blip (rk=8). Check exclusive grabber:

```bash
fuser -v /dev/video0 || true
arecord -l   # MS2109 → hw:0,0

OUT=$PWD/avsync_hdmi_out/lipsync_$(date +%Y%m%dT%H%M%S)
DURATION=60 TOL_MS=42 OUT="$OUT" bash tools/avsync_lipsync_soak.sh
echo "true rc=$?"
# Artifacts: $OUT/lipsync_report.json, $OUT/lipsync_offset_timeseries.csv,
#            $OUT/arm_cpu.json, $OUT/lipsync_stdout.txt
```

### Manual (same binding)

```bash
python3 tools/avsync_measure_hdmi.py \
  --duration 60 \
  --video-dev /dev/video0 --audio-dev hw:0,0 \
  --video-size 1920x1080 --cap-fps 30 \
  --warmup-frames 20 --tol-ms 42 --slope-tol-ms-per-s 0.5 \
  --out "$OUT" --label live60 \
  --cpu-pct-json "$OUT/arm_cpu.json"
echo "true rc=$?"
```

### Pre-registered predictions (score hit/miss after soak)

| ID | Prediction | PASS band | FAIL |
|----|------------|-----------|------|
| P_MEDIAN | raw \|median\| on soak480 @ LEAD=40 | **< 80 ms** | ≥80 ms |
| P_SLOPE | \|slope_ms_per_s\| over n≥40 | **< 0.5** | ≥0.5 → DRIFT |
| P_CLASS | timing_class | STABLE or WANDER | MONOTONIC_DRIFT |
| P_WANDER | residual_rms_ms | report only; elevated OK if judder couples | — |
| P_CPU | arm_cpu_pct | present as `measured` | NO-DATA without reason |

**Model falsifier:** if P_MEDIAN fails hard (>150 ms) with margin OK and
STABLE class, lipsync defect is real (not judder-only). If WANDER_FAIL with
small median, scheduling/judder couples into A/V phase — different fix than
LEAD knob.

### B. Device falsifier — LEAD delta must move MEASURED offset

Env override preferred (conf is user-owned; never silently normalise):

```bash
CONF=/media/fat/misterplex/misterplex.conf
BAK=/media/fat/misterplex/misterplex.conf.bak_lead_$(date +%Y%m%d%H%M%S)
cp -a "$CONF" "$BAK"

# Arm A
MISTERPLEX_AV_PRESENT_LEAD_MS=40   # restart daemon; play soak480 ≥70 s
# soak → median_A (raw_uncalibrated OK)

# Arm B
MISTERPLEX_AV_PRESENT_LEAD_MS=20
# soak → median_B

cmp -s "$BAK" "$CONF" && echo CONF_UNCHANGED_OK
# restore if anything wrote conf
```

| Check | PASS | FAIL |
|-------|------|------|
| daemon setpoint A/B | −40 / −20 | else |
| **Δmedian = median_B − median_A** | **∈ [+12, +28] ms** (≈ +20) | outside |
| conf cmp | identical | any write |
| absolute lipsync from one arm | **forbidden** | — |

PASS here proves the metric **tracks the setpoint**, not absolute lip-sync.
Grabber remains the only GT.

**Prediction:** lowering lead advances video presents → audio appears **later**
vs flash → **positive** Δoffset_ms ≈ +Δlead.

---

## What this does / does not prove

| Proves | Does not prove |
|--------|----------------|
| Real flash↔beep offset time series on HDMI | That `av_drift_ms` is lipsync |
| Drift vs wander (different fixes) | Absolute device lipsync without known-zero cal |
| Instrument sees injected defects (100→99 ms) | Confirmed video skip rate (ERROR 18/19) |
| Margin refusal when sampling inadequate | — |

**If audio sync is CORRECT:** acceptable, but only with margin proof that a
defect would have been visible (prove100 + live margin_ok).
