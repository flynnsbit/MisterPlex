# PARENT — lipsync NOW (fixture already on PMS)

Branch: `w-avsync-lane` @ worktree  
`.worktrees/w-avsync-lane` tip: re-verify with `git -C … log -1 --oneline`

## Settled (do not re-litigate)
- `av_drift_ms` = **setpoint deadband** (S3, device-confirmed `min≈−LEAD`). **Never lipsync GT.**
- Grabber **has audio**: MS2109 card0 → ALSA **`hw:0,0`** + `/dev/video0`.
- Warm-up discard **20** frames (MS2109 junk floor ~13–15 + margin).
- Absolute median without external HDMI generator cal = **`raw_uncalibrated`** only.
- Attributable now: **Δ(rk21−rk20)**, slope, residual RMS. Not the absolute level.

## Host instrument RED/GREEN (measured this session, no device)

| Gate | Result | true rc |
|------|--------|--------:|
| `tests/unit/test_avsync_measure_hdmi.sh` | **36/36** pass; adelay ladder RMSE **0.9487 ms** | **0** |
| `MODE=host bash tools/avsync_plus100_ab.sh` (AudioID 60s pair) | **Δ = +99.2885 ms** `INSTRUMENT_RESOLVES_100MS` (zero≈82.0, plus≈181.3, n=30/30) | **0** |
| file aligned blip 12 s | median **0.0000 ms**, n_pairs=12 | **0** |
| file adelay **+200 ms** + file cal | median **199.0 ms** → **`OFFSET_FAIL`** | **2** |
| `arecord -D hw:0,0 -d1` | **192044** bytes (=48000×2×2+44) | **0** |

Sign: `offset_ms=(t_beep−t_flash)×1000` · **positive = audio LATE** (lags video).  
Every printed field tagged `measured` | `caller_supplied` | `DEFAULT_ASSUMED`.  
Instrument **never** reads `av_drift_ms`.

---

## Cast these ratingKeys (NOT rk=6)

| rk | Role |
|---:|------|
| **20** | Glass 480p24 600s — design offset **0**, marker period **2.0 s** |
| **21** | same + design **+100 ms** audio — **must** show Δ≈+100 |
| 23 / 24 | AudioID 60s pair (shorter alt) |
| 27 | Bank480 1200s long soak (period 2 s if markers present) |

**Do not** cast rk=6 for lipsync (S3 LEAD asset — no usable flash/beep path for this tool).

## PRE-REGISTER (publish hit/miss after device run)

| ID | Prediction |
|----|------------|
| P1 | rk=20 @60s: n_flashes≥20 n_beeps≥20 n_pairs≥20 |
| P2 | rk=20: no `DISPLAY_FLAT` / no_flash_class defect |
| P3 | **Δ(rk21−rk20) median ∈ [+85, +115] ms** (attributable; B cancels) |
| P4 | `artifact_pair` rbf+daemon both `measured` (not NO-DATA) |
| P5 | SCORE line never contains av_drift_ms |
| P6 | soak rc ∈ {0, 2, 4, 5, 6} or honest 77 — **never** promote 77 to pass |

If P1/P2 miss → stop; do not invent lipsync from av_drift. Use `no_flash_class`.

---

## PASTE 1 — baseline rk=20

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
HOST=${MISTER_HOST:-192.168.1.183}
fuser -v /dev/video0 || true          # must be free
arecord -l | head -8                  # expect MS2109 → hw:0,0

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
grep -E '^(SCORE |VERDICT=|n_flashes=|n_beeps=|n_pairs=|median_offset|no_flash|artifact_pair=|timing_class=|session_epoch)' \
  "$OUT/soak_wrap.txt" "$OUT/rk20_stdout.txt" 2>/dev/null
echo "OUT_RK20=$OUT"
```

Artifacts: `$OUT/epoch.txt` · `artifacts.json` · `rk20_stdout.txt` · `rk20_offset_timeseries.csv` · `rk20_report.json` · `arm_cpu.json`

---

## PASTE 2 — +100 ms twin rk=21

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
HOST=${MISTER_HOST:-192.168.1.183}
scripts/plex_browse.sh --player ${HOST}:3005 play 21
sleep 5
OUT1=$PWD/avsync_hdmi_out/live21_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT1"
bash tools/avsync_capture_session_epoch.sh | tee "$OUT1/epoch.txt"
echo "epoch true rc=$?"

DURATION=60 MARKER_PERIOD_S=2.0 MIN_PAIRS=20 TOL_MS=200 \
  NO_ABSOLUTE_SCORE=1 DECODE_SRC=caller_supplied WARMUP_FRAMES=20 \
  LABEL=rk21 OUT="$OUT1" \
  bash tools/avsync_lipsync_soak.sh >"$OUT1/soak_wrap.txt" 2>&1
echo "soak_rk21 true rc=$?"
grep -E '^(SCORE |VERDICT=|n_flashes=|n_beeps=|n_pairs=|median_offset|no_flash|timing_class=)' \
  "$OUT1/soak_wrap.txt" "$OUT1/rk21_stdout.txt" 2>/dev/null
echo "OUT_RK21=$OUT1"

# Δ — set RK20_STDOUT / RK21_STDOUT from echoes above
RK20_STDOUT=PASTE_OUT_RK20/rk20_stdout.txt \
RK21_STDOUT=PASTE_OUT_RK21/rk21_stdout.txt \
python3 - <<'PY'
import os, re
from pathlib import Path
def med(p):
    t = Path(p).read_text(errors="replace")
    m = re.search(r"^median_offset_ms_raw=([-\d.]+)", t, re.M)
    return float(m.group(1)) if m else None
a = med(os.environ["RK20_STDOUT"])
b = med(os.environ["RK21_STDOUT"])
d = None if a is None or b is None else b - a
print(f"median_20={a} median_21={b} delta_ms={d} src=measured tag=same_rig_B_cancels")
print("expect_delta_ms≈+100 band=[+85,+115] src=caller_supplied_design")
if d is not None and 85 <= d <= 115:
    print("VERDICT=LIVE_PLUS100_RESOLVED")
elif d is None:
    print("VERDICT=NO-DATA")
else:
    print("VERDICT=LIVE_PLUS100_MISS")
PY
```

Optional one-shot A/B helper (cast 20, run zero arm, cast 21, run plus arm):
```bash
OUT=$PWD/avsync_hdmi_out/ab100_$(date +%Y%m%dT%H%M%S); mkdir -p "$OUT"
# while rk=20 playing:
MODE=live ARM=zero ARM_S=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=10 OUT="$OUT" \
  bash tools/avsync_plus100_ab.sh; echo "zero true rc=$?"
# cast 21, then:
MODE=live ARM=plus ARM_S=45 MARKER_PERIOD_S=2.0 MIN_PAIRS=10 OUT="$OUT" \
  bash tools/avsync_plus100_ab.sh; echo "plus100_ab true rc=$?"
```

---

## PASTE 3 — external LEAD falsifier (AFTER P1–P3 green)

**Question:** does **grabber** lipsync track `AV_PRESENT_LEAD_MS`, or only the circular `av_drift_ms`?

| LEAD | Pre-reg: external median Δ vs LEAD=40 | Pre-reg: av_drift min |
|-----:|---------------------------------------|------------------------|
| 20 | \|Δ_ext\| **< 25 ms** (does **not** jump −20) | min ≈ **−20** |
| 40 | baseline | min ≈ **−40** |
| 80 | \|Δ_ext\| **< 25 ms** (does **not** jump −40) | min ≈ **−80** |

- If external offset **stays put** while av_drift min tracks −LEAD → S3 confirmed on **both** sides; lipsync GT = HDMI only.
- If external offset **moves with LEAD** → pacer is shifting real glass A/V (different finding; still not “av_drift is lipsync”).

Conf key: `AV_PRESENT_LEAD_MS`. Backup/restore conf **byte-exact `cmp`** (same protocol as S3 device run). Per arm: restart daemon, verify banner LEAD, cast **rk=20**, 60 s soak, scrape HDMI median + daemon av_drift min. One session_epoch per arm.

---

## If soak returns flashes=0 / beeps=0
| Class | Meaning |
|-------|---------|
| DISPLAY_FLAT | not painting / idle — glass problem |
| WINDOW_TOO_SHORT | raise DURATION |
| VIDEO_BUSY | `fuser -v /dev/video0` |
| beeps=0 only | wrong ALSA card; `arecord -l` MS2109 |
| rc=77 | **UNSCORED / NO-DATA — not a pass, not a defect claim** |

Black mean luma ~7 with **zero** flashes after 60 s ≠ healthy flash duty.

## Validated on hardware (parent 2026-08-01)
P1–P6 **HIT**. Live Δ(rk21−rk20)=**+111.50 ms**. Instrument validated through full path.
**WANDER** observed (residual up to 224 ms) while daemon still `av-lock av_drift_ms=-39` at vfps 18.3 — next work: `docs/AVSYNC_WANDER_RCA.md`.

## Host re-check (no device)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
bash tests/unit/test_avsync_measure_hdmi.sh; echo "unit true rc=$?"
OUT=$PWD/.agent-work/w-avsync/plus100_host_recheck MODE=host \
  bash tools/avsync_plus100_ab.sh; echo "plus100 true rc=$?"
```
