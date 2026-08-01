# Parent lipsync card — pasteable (device recovered)

Agent does **not** touch the device. You cast + capture.

## Pre-conditions (you verify)
- core=Plex, daemon up, conf untouched
- Playing **blip fixture** with full-frame white flash + 1 kHz beep / 1.0 s
  - Prefer rk=8 soak480 **or** product 320x240 blip @ **24.000** (not 23.976)
  - Generator: `flash_s = 2.0/fps` → duty **8.33%** (host-measured on
    `assets/avsync/sync_24fps_blip.mp4`: duty_hot=0.0833, contrast≈233)
- `/dev/video0` free: `fuser -v /dev/video0`
- ALSA: `arecord -l` → MS2109 `hw:0,0`

## Fixture math (not guessed)
| Quantity | Value | src |
|----------|------:|-----|
| flash period | 1.0 s | caller_supplied gen_avsync_blip |
| flash duration | 2/24 = 0.0833 s | caller_supplied generator |
| duty | 0.0833 | measured file = generator |
| beep | 50 ms @ 1 kHz | caller_supplied |
| min capture for 40 pairs @30 fps warmup20 | **41.67 s** | derived |
| recommended DURATION | **60** | caller_supplied margin |

## Pre-registered predictions (score hit/miss after)
| ID | Prediction |
|----|------------|
| P_MEDIAN | \|offset_ms\| raw < 80 ms @ LEAD=40 (`raw_uncalibrated`) |
| P_SLOPE | \|slope_ms_per_s\| < 0.5 for n≥40 |
| P_CLASS | STABLE or WANDER (not MONOTONIC_DRIFT) |
| P_FLASH | n_flashes ≥ 40; **no** `no_flash_class=DISPLAY_FLAT` |
| P_BEEP | n_beeps ≥ 40 |
| P_CPU | arm_cpu_pct src=measured |
| P_DISCRIM | if rc=77 and n_beeps>0: class is DISPLAY_FLAT / WINDOW_TOO_SHORT / THRESHOLD_NO_TRIGGER (not a blob) |

## Commands (capture true rc DIRECTLY)

```bash
cd /home/flynnsbit/Projects/MisterPlex
# 1) optional host gate (no device)
python3 tools/avsync_measure_hdmi.py --self-test > .agent-work/w-avsync/self_pre.out 2>&1
echo "self true rc=$?"

# 2) LIVE soak — cast blip FIRST, then:
fuser -v /dev/video0 || true
OUT=$PWD/avsync_hdmi_out/lipsync_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"
DURATION=60 TOL_MS=42 MIN_PAIRS=40 OUT="$OUT" \
  bash tools/avsync_lipsync_soak.sh >"$OUT/soak_wrap.txt" 2>&1
echo "soak true rc=$?"
# Artifacts
grep -E '^(SCORE |VERDICT=|no_flash_class=|session_gate|P_|n_flashes=|n_beeps=)' \
  "$OUT/soak_wrap.txt" "$OUT/lipsync_stdout.txt" 2>/dev/null | head -80
echo "report=$OUT/lipsync_report.json"
echo "series=$OUT/lipsync_offset_timeseries.csv"
echo "session=$OUT/session_gate.txt"
```

Skip session gate only if you must: `SKIP_SESSION_GATE=1` (not recommended).

## Discriminator (if rc=77)
| no_flash_class | Meaning |
|----------------|---------|
| **DISPLAY_FLAT** | Span long enough; luma_contrast < 40; beeps may be >0 → glass idle/black/no flash (your prior wedged case) |
| **WINDOW_TOO_SHORT** | analysis_span < min_pairs×1s |
| **THRESHOLD_NO_TRIGGER** | contrast OK but zero flash onsets (detector bug) |

## Tags discipline (ERROR 17)
Every value printed with `src=measured|caller_supplied|DEFAULT_ASSUMED`.
Scoring with DEFAULT_ASSUMED tol without `--tol-ms` → `REFUSE_DEFAULT_ASSUMED rc=77`.

## Host banked (no device)
```
aligned file:  SCORE offset_ms=0.0000  rc=0
adelay +100ms: SCORE offset_ms=99.0000 rc=2 OFFSET_FAIL
flat+beeps:    no_flash_class=DISPLAY_FLAT rc=77 n_beeps=12
unit gate:     AVSYNC_MEASURE_HDMI_OK pass=28
```

## Sign
offset_ms = (t_beep − t_flash)×1000; **positive = audio LATE**.
Never uses PLXD frames_done/presents/drops/unaccounted.
