# PARENT LIPSYNC RUN CARD — ready (RBF 78eff44e rendering)

Agent never touches the device. You cast + run this.

## Why not av_drift_ms (dead on arrival)

`host/libmisterplex/av_clock.hpp:280-283` (quoted):

```
// avDecide HOLDs while drift + lead < 0, so in steady state the *observed*
// av_drift_ms sits in approximately [-lead, drop) BY CONSTRUCTION. That band
// is a readout of AV_PRESENT_LEAD_MS, not an independent lipsync accuracy.
```

Telemetry self-labels `av_drift_role=servo_error_not_lipsync` (`:319`).
**This instrument never reads av_drift_ms / PLXD / presents / drops.**

## Audio path — EXISTS (host-enumerated this session)

```
$ arecord -l   # true rc=0
card 0: MS2109 [MS2109], device 0: USB Audio [USB Audio]
$ v4l2-ctl --list-devices
UVC Camera (534d:2109): ... /dev/video0
$ fuser -v /dev/video0   # true rc=1 → free (nothing holds it)
```

ONE ffmpeg: v4l2 `/dev/video0` + ALSA `hw:0,0`, both `-use_wallclock_as_timestamps 1`,
`-copyts -start_at_zero`. Warmup discard **20** frames (MS2109 junk).

## Method
- Video: full-frame white flash onsets (luma thr; duty 8.33% = 2/24 s per generator)
- Audio: 1 kHz beep onset (Goertzel)
- `offset_ms = (t_beep − t_flash)×1000` → **+ = audio LATE**
- SCORE line: offset_ms, sigma_ms, se_median_ms, uncertainty_ms, n, timing_class, residual_rms_ms

## 30 s asset NOW / long later
| Asset | DURATION | MIN_PAIRS | min capture needed |
|-------|----------|-----------|--------------------|
| 30 s PMS (rk=6 class) | **30** | **15** | 16.67 s @30fps w20 |
| long (w-asset480) | 60 | 40 | 41.67 s |

## Pre-registered (score hit/miss after YOU run)

| ID | Prediction |
|----|------------|
| P1 | \|SCORE offset_ms\| < 80 ms raw @ LEAD=40 (`tag=raw_uncalibrated`) |
| P2 | n_flashes ≥ 15 and n_beeps ≥ 15 on 30 s blip play |
| P3 | no_flash_class **absent** (not DISPLAY_FLAT — screen is rendering) |
| P4 | timing_class STABLE or WANDER; \|slope\| gate soft if n&lt;20 |
| P5 | uncertainty_ms ≥ half frame quant (~16.7 @30 fps) |
| P6 | rc≠77 unless named check fails (session gate / busy grabber / wrong asset) |

## Exact command (paste)

```bash
cd /home/flynnsbit/Projects/MisterPlex

# 0) grabber free?
fuser -v /dev/video0 || true
arecord -l | head -5

# 1) Cast blip fixture with flash+beep (30 s asset OK). Confirm FLASH on glass.

# 2) Capture+score (default DURATION=30 MIN_PAIRS=15)
OUT=$PWD/avsync_hdmi_out/lipsync_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT" .agent-work/w-avsync
DURATION=30 TOL_MS=42 MIN_PAIRS=15 OUT="$OUT" \
  bash tools/avsync_lipsync_soak.sh >"$OUT/soak_wrap.txt" 2>&1
echo "soak true rc=$?"
cp -a "$OUT" .agent-work/w-avsync/last_soak 2>/dev/null || true

# 3) Read the number
grep -E '^(SCORE |VERDICT=|no_flash_class=|n_flashes=|n_beeps=|session_gate)' \
  "$OUT/soak_wrap.txt" "$OUT/lipsync_stdout.txt" 2>/dev/null
echo "report=$OUT/lipsync_report.json series=$OUT/lipsync_offset_timeseries.csv"
```

Long fixture later: `DURATION=60 MIN_PAIRS=40 OUT=... bash tools/avsync_lipsync_soak.sh`

Skip session gate only if broken: `SKIP_SESSION_GATE=1` (prefer fix gate).

## Host gates already green (no device)
```
self-test true rc=0
unit test_avsync_measure_hdmi.sh true rc=0  (29/29)
prove100: offset_ms=0 rc=0; adelay+100 → offset_ms=99 rc=2 OFFSET_FAIL
DISPLAY_FLAT RBG: black+beeps → no_flash_class=DISPLAY_FLAT rc=77
```

## If rc=77 now
| no_flash_class | Meaning |
|----------------|---------|
| DISPLAY_FLAT | glass still flat (cast idle / wrong item) |
| WINDOW_TOO_SHORT | duration/min_pairs mismatch |
| THRESHOLD_NO_TRIGGER | contrast OK, detector bug |

## Absolute vs relative
Without known-zero cal into grabber, SCORE offset is `raw_uncalibrated` (includes fixed grabber A/V skew B). Same-rig ΔLEAD and slope cancel B. LEAD 40→20 must move median ≈+20 ms ∈ [+12,+28].
