# Parent soak — after marker fixture is on PMS

## Preconditions
- Fixture with period **2.000 s** full-frame white flash + 1 kHz/50 ms beep (w-asset480 batch)
- Counter readable on white flash (black text or yellow-in-black-box)
- Cast playing; `session_epoch` single; `/dev/video0` free; ALSA `hw:0,0` free
- **Do not** use `av_drift_ms` / av-lock as lipsync

## Attribution rules
| Quantity | Tag | Use |
|----------|-----|-----|
| median offset alone | `raw_uncalibrated` | forensic only — **not** accuracy claim |
| Δ vs +100 twin / LEAD A/B / seek | measured, B cancels | attributable |
| slope_ms_per_s | measured | attributable drift rate |
| av_drift_ms | **retired** | never lipsync |

## Exact invocation

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
# or: git fetch && git checkout w-avsync-lane

fuser -v /dev/video0 || true
arecord -l | head -6

OUT=$PWD/avsync_hdmi_out/lipsync_$(date +%Y%m%dT%H%M%S)
mkdir -p "$OUT"

# Stamp epoch before soak
bash tools/avsync_capture_session_epoch.sh | tee "$OUT/epoch.txt"
echo "epoch true rc=$?"

DURATION=60 \
MARKER_PERIOD_S=2.0 \
MIN_PAIRS=20 \
TOL_MS=200 \
NO_ABSOLUTE_SCORE=1 \
DECODE_SRC=caller_supplied \
WARMUP_FRAMES=20 \
LABEL=lipsync \
OUT="$OUT" \
  bash tools/avsync_lipsync_soak.sh >"$OUT/soak_wrap.txt" 2>&1
echo "soak true rc=$?"

grep -E '^(SCORE |VERDICT=|median_offset|n_flashes=|n_beeps=|n_pairs=|timing_class=|slope_ms|artifact_pair=|no_flash_class=)' \
  "$OUT/soak_wrap.txt" "$OUT"/lipsync_stdout.txt 2>/dev/null
```

### Expected artifacts
| Path | Content |
|------|---------|
| `$OUT/epoch.txt` | `session_epoch=…` measured |
| `$OUT/artifacts.json` | rbf_md5 + daemon_md5 pair |
| `$OUT/lipsync_stdout.txt` | full tagged report |
| `$OUT/lipsync_offset_timeseries.csv` | per-pair t_flash, t_beep, offset_ms |
| `$OUT/lipsync_report.json` | machine JSON |
| `$OUT/arm_cpu.json` | concurrent ARM CPU% |
| `$OUT/soak_wrap.txt` | wrapper + true rc context |

### Expected PASS shape (fixture good)
- `n_flashes ≥ 20`, `n_beeps ≥ 20`, `n_pairs ≥ 20`
- `no_flash_class` absent
- `timing_class` STABLE or WANDER (not required PASS on absolute)
- `median_offset_ms` printed `tag=raw_uncalibrated`
- `VERDICT=PASS` only with `no_absolute_score=1` on slope/wander — **not** an absolute lipsync claim
- rc=0 on slope OK; rc=77 if DISPLAY_FLAT / session / VIDEO_BUSY

### +100 twin (attributable)
```bash
# After zero-offset soak, cast audioPlus100ms twin, same OUT parent dir:
OUT0=$OUT  # prior
OUT1=$PWD/avsync_hdmi_out/lipsync100_$(date +%Y%m%dT%H%M%S)
# … same soak into OUT1 …
# delta = median_100 - median_0  expect ≈ +100 ± 15
```
Or: `MODE=live ARM=zero|plus bash tools/avsync_plus100_ab.sh`

### Fail patterns
| Symptom | Meaning |
|---------|---------|
| flashes=0 beeps>0 | DISPLAY_FLAT / wrong paint |
| both 0 | wrong asset or capture dead |
| VIDEO_BUSY | fuser /dev/video0 |
| multi session_epoch | do not pool |
