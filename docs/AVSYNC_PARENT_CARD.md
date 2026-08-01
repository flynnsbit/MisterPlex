# PARENT LIPSYNC RUN CARD (long soak + transitions)

## AUDIO PATH (settled)
MacroSilicon `534d:2109` = `/dev/video0` + ALSA `hw:0,0` (card MS2109), same USB.
One ffmpeg, wallclock+copyts. **Never** `av_drift_ms` (servo deadband).

## Sign / tags
`offset_ms=(t_beep−t_flash)×1000` · **+ = audio LATE**  
Every value: `measured` | `caller_supplied` | `DEFAULT_ASSUMED`  
Absolute median without known-zero cal = `raw_uncalibrated` (grabber B unknown).  
Same-rig **Δ** and **slope** cancel B.

## Fixture rk=27
`/library/metadata/27` · 624×480 · 24.000 fps · **1200 s** · markers every **2.000 s** · design offset 0.  
**Do not loop** a short clip for long soaks (stream counters reset).

## Power table (σ_res=16 ms parent pilot, period=2 s, z=2.8 ≈ 80% power)

| duration | n≈ | δ_min (ms/s) @80% | cum @ δ_min over span |
|---------:|---:|------------------:|----------------------:|
| 60 s     | 28 | 0.524             | ~28 ms                |
| 900 s    | 448| **0.0082**        | ~7.3 ms               |
| 1200 s   | 598| **0.0053**        | ~6.3 ms               |

Null `|slope|<δ_min` ⇒ cannot reject zero drift at 80% power — **not** proof of perfect sync.

## Pre-register (publish hit/miss after)

| ID | Prediction |
|----|------------|
| L1 | 15 min soak: n_pairs ≥ 0.8×expected (~358 @900s) |
| L2 | If \|slope\| < δ_min → `drift_null_at_80pct_power=1` |
| L3 | no DISPLAY_FLAT; artifact_pair both md5 measured |
| T1 | seek: \|Δmedian\| < 80 ms after settle (STEP_TOL) |
| T2 | pause_resume: same STEP_TOL |
| T3 | pre and post each n_pairs ≥ MIN_PAIRS |

---

## PASTE 1 — Long soak 15 min (rk=27 already playing, session established)

```bash
cd /home/flynnsbit/Projects/MisterPlex
fuser -v /dev/video0 || true   # must be free
arecord -l | head -6
OUT=$PWD/avsync_hdmi_out/long_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"
DURATION=900 MARKER_PERIOD_S=2.0 SIGMA_RES_MS=16.0 \
  SIGMA_SRC=measured_parent_480p_pilot DECODE_SRC=caller_supplied \
  OUT="$OUT" LABEL=long900 \
  bash tools/avsync_long_soak.sh >"$OUT/wrap.txt" 2>&1
echo "long_soak true rc=$?"
grep -E '^(SCORE |VERDICT=|min_detectable|measured_slope|drift_null|n_pairs=|artifact_pair=|slope_ms)' \
  "$OUT/wrap.txt" "$OUT/long900_stdout.txt" 2>/dev/null
```

Optional full fixture length: `DURATION=1200`.

---

## PASTE 2 — Transition SEEK (playing rk=27)

```bash
cd /home/flynnsbit/Projects/MisterPlex
OUT=$PWD/avsync_hdmi_out/xseek_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"
TRANSITION=seek SEEK_MS=120000 ARM_S=30 SETTLE_S=8 \
  MARKER_PERIOD_S=2.0 MIN_PAIRS=10 STEP_TOL_MS=80 \
  DECODE_SRC=caller_supplied OUT="$OUT" \
  bash tools/avsync_transition_harness.sh >"$OUT/wrap.txt" 2>&1
echo "transition_seek true rc=$?"
grep -E '^(SCORE_TRANSITION|VERDICT=|pre_median|post_median|delta_median|arm=)' \
  "$OUT/wrap.txt"
```

---

## PASTE 3 — Transition PAUSE→RESUME

```bash
cd /home/flynnsbit/Projects/MisterPlex
OUT=$PWD/avsync_hdmi_out/xpause_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"
TRANSITION=pause_resume ARM_S=30 SETTLE_S=8 \
  MARKER_PERIOD_S=2.0 MIN_PAIRS=10 STEP_TOL_MS=80 \
  DECODE_SRC=caller_supplied OUT="$OUT" \
  bash tools/avsync_transition_harness.sh >"$OUT/wrap.txt" 2>&1
echo "transition_pause true rc=$?"
grep -E '^(SCORE_TRANSITION|VERDICT=|delta_median|pre_median|post_median)' "$OUT/wrap.txt"
```

---

## Short steady-state (unchanged soak)

```bash
OUT=$PWD/avsync_hdmi_out/ss_$(date +%Y%m%dT%H%M%S)
DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 TOL_MS=200 DECODE_SRC=caller_supplied OUT="$OUT" \
  bash tools/avsync_lipsync_soak.sh >"$OUT/soak_wrap.txt" 2>&1
echo "soak true rc=$?"
```

Note: uncalibrated \|median\|~100+ ms → `ABS_OFFSET_UNSCOREABLE` rc=77 (not OFFSET_FAIL).  
Long/transition harnesses pass `--no-absolute-score` so slope/Δ can PASS without pretending absolute is calibrated.

## Host green (this agent)
- `python3 tools/avsync_measure_hdmi.py --self-test` rc=0  
- `python3 tools/avsync_drift_power.py --self-test` rc=0  
- `bash tests/unit/test_avsync_measure_hdmi.sh` **36/36** rc=0  
- adelay ladder RMSE ~0.95 ms  

## Agent never touches device
Parent casts, captures, deploys. Capture rc: `cmd; echo "true rc=$?"` never through a pipe.
