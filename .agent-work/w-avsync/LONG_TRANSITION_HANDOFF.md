# w-avsync handoff — long soak + transitions

## Delivered
| Path | Role |
|------|------|
| `tools/avsync_drift_power.py` | δ_min slope @ 80% power (equal-spaced OLS) |
| `tools/avsync_long_soak.sh` | 15–20 min soak; prints δ_min then measures with `--no-absolute-score` |
| `tools/avsync_transition_harness.sh` | pre → seek\|pause_resume → settle → post → Δmedian |
| `tools/avsync_measure_hdmi.py` | `--marker-period-s` (rk=27=2.0), `--no-absolute-score` |
| `tools/avsync_lipsync_soak.sh` | `MARKER_PERIOD_S` env |
| `docs/AVSYNC_PARENT_CARD.md` | paste commands |
| unit | 36/36 PASS |

## Power (σ=16 ms, period=2 s)
- 60 s → δ_min ≈ **0.52 ms/s**
- 900 s → δ_min ≈ **0.0082 ms/s**
- 1200 s → δ_min ≈ **0.0053 ms/s**

## Transition
- Companion HTTP `MISTER_HOST:3005` pause/play/seekTo
- `delta_median_ms = post − pre` (B cancels)
- STEP_TOL_MS default 80; FAIL → rc=2 `TRANSITION_STEP_FAIL`

## Not done by this lane
- Known-zero absolute cal (w-instr)
- Device cast/deploy/HDMI run (parent)
- av_drift_ms (forbidden)

## Pre-register miss protocol
Parent publishes L1–T3 hit/miss after run; agent does not invent glass results.
