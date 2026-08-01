# w-lint — av_drift_ms / av-lock are blind to lip-sync

**Date:** 2026-07-31 (parent fleet broadcast)  
**Lane:** w-lint gate-integrity  

## Measurement (parent, fixture rk8, five same-config 480p runs)

HDMI offset medians (ms, raw_uncalibrated):

| run | median HDMI offset |
|-----|-------------------|
| 1 | -318.0 |
| 2 | -316.0 |
| 3 | -304.7 |
| 4 | -196.7 |
| 5 | -196.0 |

Two clusters ~116–120 ms apart under identical conf/daemon/core/PMS/fixture.

Daemon 1 Hz `av_drift_ms` series (~220 samples) on three of those runs:

| run | mean av_drift_ms | slope |
|-----|------------------|-------|
| rep1 | -29.8 | -0.0034 ms/s (−3 ppm) |
| rep2 | -29.4 | -0.0025 ms/s (−3 ppm) |
| rep3 | -30.2 | -0.0017 ms/s (−2 ppm) |

Daemon reports all three identical within 0.8 ms while HDMI is 120 ms apart.

## Source (why this is by construction)

`host/libmisterplex/av_clock.hpp`:

- `audioClockMs` hardcodes 48000 × 4 bytes/sample (no PPM trim).
- `avDriftMs = audioMs - frameMs` from internal counters only.
- `avDecide` holds/drops inside `leadMs` / `dropMs` deadband — the logged
  `av_drift_ms` is the servo residual after that policy, not external A/V phase.

Also noted (parent): `arm/misterplexd/media_player.hpp` default
`audioClockPpm_ = -638` while the pacer clock is untrimmed 48000 — asymmetry
not attributed; do not build on an untested link.

## Binding rule (every lane)

- `clock=av-lock` and `av_drift_ms` are **NOT** soak PASS criteria.
- Soft-skip / UNSCORED / missing instrument ≠ PASS.
- Only external pixel+audio instruments judge lip-sync:
  - `tests/hw/avsync_measure.py`
  - `tests/hw/avsync_rate.py`
  - `tools/avsync_measure_hdmi.py` (parent grabber)

## Steady-state drops (related falsification)

1 Hz sampling across three 360 s soaks: `drops` final by wall_s≈7; zero further
increments across ~353 s. Startup-only drops (12–18); no steady-state sawtooth.

## w-lint code changes

| Path | Change |
|------|--------|
| `scripts/validate_playback_controls_hw.sh` | Removed `pass`/`fail` on `av_drift_ms`; emit `TELEMETRY_ONLY not_lip_sync` |
| `tests/hw/test_p480_ab_harness.sh` | HDMI unscored path no longer claims log av_drift "still counts" |
| `tests/unit/test_av_drift_not_lipsync_pass.py` | Static guard; RBG both dirs |
| `Makefile` unit-unlocked | Wires the guard |
| `tests/unit/test_unit_rollcall.py` | `--write-expected` → 125 protected commands |

## Direct true rc (host)

```
python3 tests/unit/test_av_drift_not_lipsync_pass.py; echo "true rc=$?"  # 0
# injected pass "av_drift_ms..." → true rc=1; removed → 0
python3 tests/unit/test_unit_rollcall.py; echo "true rc=$?"  # 0
```


**Branch tip:** `w-lint-gate-integrity` @ `e5ce4759`
