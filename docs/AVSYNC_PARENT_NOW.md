# PARENT — lipsync NOW (fixture already on PMS)

## Settled
- `av_drift_ms` = setpoint deadband (S3). **Never lipsync GT.**
- Grabber: `/dev/video0` + ALSA **`hw:0,0`** (MS2109). Warm-up discard **20** frames.
- Host instrument RED/GREEN (file path, measured):
  - GlassAV 0 vs +100: **Δ = +99.9978 ms**, `VERDICT=INSTRUMENT_RESOLVES_100MS` rc=0
  - verify: offset0 ≈ −0.14 ms; offset100 ≈ +99.86 ms

## Cast these ratingKeys (NOT rk=6, NOT plain BBB)

| rk | Title | Role |
|---:|-------|------|
| **20** | AVSync Glass 480p 24fps 600s | offset **0**, period **2.0 s** |
| **21** | … audioPlus100ms | design **+100 ms** (must show Δ≈+100) |
| 23 / 24 | AudioID 60s pair | shorter alt +100 twin |
| 27 | Bank480 FullBleed VRes AV 1200s | long soak (markers @2s if present) |

**Do not** cast rk=6 for lipsync (parent S3 asset — no usable flash/beep for this instrument).

## Sign / tags
`offset_ms=(t_beep−t_flash)×1000` · **+ = audio LATE**  
Absolute median: **`raw_uncalibrated`** only.  
Attributable: **Δ(rk21−rk20)**, slope. Every line tagged measured|caller_supplied|DEFAULT_ASSUMED.

## PRE-REGISTER (publish hit/miss)

| ID | Prediction |
|----|------------|
| P1 | rk=20: n_flashes≥20 n_beeps≥20 n_pairs≥20 on 60 s soak |
| P2 | rk=20: no `DISPLAY_FLAT` / no_flash_class |
| P3 | rk=21−rk=20: **delta_ms ∈ [+85, +115]** |
| P4 | artifact_pair rbf+daemon both measured |
| P5 | never read av_drift_ms into SCORE |

---

## PASTE 1 — baseline rk=20

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
HOST=${MISTER_HOST:-192.168.1.183}
fuser -v /dev/video0 || true          # must be free
arecord -l | head -8                  # expect MS2109 hw:0,0

# Cast AVSync Glass offset-0
scripts/plex_browse.sh --player ${HOST}:3005 play 20
sleep 5
scripts/plex_browse.sh --player ${HOST}:3005 status

OUT=$PWD/avsync_hdmi_out/live20_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"
bash tools/avsync_capture_session_epoch.sh | tee "$OUT/epoch.txt"
echo "epoch true rc=$?"

DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 TOL_MS=200 \
  NO_ABSOLUTE_SCORE=1 DECODE_SRC=caller_supplied WARMUP_FRAMES=20 \
  LABEL=rk20 OUT="$OUT" \
  bash tools/avsync_lipsync_soak.sh >"$OUT/soak_wrap.txt" 2>&1
echo "soak_rk20 true rc=$?"
grep -E '^(SCORE |VERDICT=|n_flashes=|n_beeps=|n_pairs=|median_offset|no_flash|artifact_pair=|timing_class=)' \
  "$OUT/soak_wrap.txt" "$OUT/rk20_stdout.txt" 2>/dev/null
```

### Artifacts
`$OUT/epoch.txt` · `artifacts.json` · `rk20_stdout.txt` · `rk20_offset_timeseries.csv` · `rk20_report.json` · `arm_cpu.json`

---

## PASTE 2 — +100 ms twin rk=21 (attributable Δ)

```bash
HOST=${MISTER_HOST:-192.168.1.183}
scripts/plex_browse.sh --player ${HOST}:3005 play 21
sleep 5
OUT1=$PWD/avsync_hdmi_out/live21_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT1"
bash tools/avsync_capture_session_epoch.sh | tee "$OUT1/epoch.txt"
DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 TOL_MS=200 \
  NO_ABSOLUTE_SCORE=1 DECODE_SRC=caller_supplied LABEL=rk21 OUT="$OUT1" \
  bash tools/avsync_lipsync_soak.sh >"$OUT1/soak_wrap.txt" 2>&1
echo "soak_rk21 true rc=$?"

# Δ from medians (both tag=raw_uncalibrated; Δ cancels grabber B)
python3 - <<'PY'
import re,sys
from pathlib import Path
def med(p):
    t=Path(p).read_text(errors='replace')
    m=re.search(r'^median_offset_ms_raw=([-\d.]+)',t,re.M)
    return float(m.group(1)) if m else None
# edit paths:
a=med('OUT_RK20/rk20_stdout.txt')  # paste real paths
b=med('OUT_RK21/rk21_stdout.txt')
print('median_20',a,'median_21',b,'delta',None if a is None or b is None else b-a)
print('expect_delta≈+100 src=caller_supplied_design')
PY
```

Or one-shot after both plays prepared:
```bash
# zero arm while rk=20 playing, then plus while rk=21:
OUT=$PWD/avsync_hdmi_out/ab100_$(date +%Y%m%dT%H%M%S)
MODE=live ARM=zero ARM_S=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=10 OUT="$OUT" \
  bash tools/avsync_plus100_ab.sh | tee "$OUT/zero_wrap.txt"
echo "zero true rc=$?"
# cast 21, then:
MODE=live ARM=plus ARM_S=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=10 OUT="$OUT" \
  bash tools/avsync_plus100_ab.sh | tee "$OUT/plus_wrap.txt"
echo "plus100_ab true rc=$?"
```

---

## If soak returns flashes=0
| Class | Action |
|-------|--------|
| DISPLAY_FLAT | not painting / idle — not instrument blind |
| WINDOW_TOO_SHORT | raise DURATION |
| VIDEO_BUSY | `fuser -v /dev/video0` |
| beeps=0 too | check `arecord -l` MS2109; wrong card |

Black mean luma ~7 on marker content with **zero** flashes after 60s = glass problem, not “working black flash duty”.

## Host re-check (no device)
```bash
OUT=/tmp/x MODE=host bash tools/avsync_plus100_ab.sh   # uses assets; prefer .agent-work path
# or:
bash tests/unit/test_avsync_measure_hdmi.sh; echo "unit true rc=$?"
```
