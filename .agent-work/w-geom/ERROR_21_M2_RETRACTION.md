# ERROR 21 — M2 as named mechanism RETRACTED (parent 2026-08-01)

**Status:** RETRACTED. Do not RCA “M2 PUBLISH_INTERVAL_JITTER” as an established defect.  
**Lane owner note:** w-geom published M2-forward work on `874df221` under parent’s prior brief; this document supersedes that mechanism claim.

## What still stands

| Claim | Status |
|-------|--------|
| **M1 UNDERPRODUCE_THEN_DROP falsified** on the paired window (vfps 23.9 flat, drops_delta=0 while HDMI residual_rms 14.4) | **STANDS** — real paired evidence |
| `clock=av-lock` is a hardcoded string, not health | **STANDS** |
| `av_drift_ms` = servo deadband (`av_drift_role=servo_error_not_lipsync`) | **STANDS** |
| Two-roots log default must not prefer stale v1 | **STANDS** (pair script + wait_session live resolve) |
| Standing geometry lane (FORCE_SCALE / B1 / B5) | **ACTIVE** |

## What is retracted

| Claim | Why dead |
|-------|----------|
| `drops_delta=0` evidences publish-interval behaviour | `drops` = pacer Drop only (`media_player.cpp` `!present` path). Orthogonal to publish cadence. |
| `publish_misses` measures intervals | Counts publish **failures** only (`if (!ok)`), not inter-publish timing. |
| M1 false ⇒ M2 true | Disjunctive syllogism over a self-written two-item list (ERROR-17 shape). |
| STABLE→WANDER intermittency at constant throughput | Windows statistically indistinguishable (parent p≈0.14); CIs overlap tol. **May be no intermittency.** |
| `detrended_max_abs_ms=50.8` as headline defect | Max over n=30; ~1.5 capture periods; prefer p95. |
| Lipsync residual RMS as the user’s “dropped frames” | User symptom is judder/presentation-interval; instrument is flash↔beep **lipsync**. Orthogonal channel. |
| “Didn’t look 480p” as this lane | 240-row ceiling / pitch; fixed on RBF `8fdf440f`. Out of scope. |

## Correct published position (parent)

> In two 60 s windows at DECODE=624x480 with nominal frame production (vfps 23.9 flat) and no pacer drops, glass-side A/V residual RMS measured 10.9 and 14.4 ms against a 12.4 ms tolerance. The two windows are statistically indistinguishable and both lie within ~1.3× of the instrument’s quantisation floor. **No device-side defect is established and no mechanism is identified.** Publish-interval behaviour was not measured (as a defect).

**Unknown is correct.**

## Code left in tree (not a defect claim)

- `pub_iv_*` 1 Hz fragment and rolling window in `publish_interval_ledger.hpp` remain as **optional telemetry** if a future motion instrument needs ARM-side arrival stamps.
- They must **not** be scored as PASS/FAIL for a device defect until an independent motion/judder instrument (w-instr inter-frame histogram) establishes a symptom.
- Correlator primary mechanism after this commit: **`UNKNOWN`** (M1 falsify tag only when shape matches).

## Motion / judder (out of this lane)

Right measurement: **inter-frame-interval histogram** on capture (peak ~41.7 ms @24; mass at ~83 ms = drop/repeat). **w-instr owns** — do not duplicate.
