# Startup drop-count variance RCA (w-cpu)

**Scope:** source analysis + host unit model. No device access.
**ERROR 17:** retracted — fixtures are 24.000 fps; `fps=24/1` is correct.

## Fleet corrections absorbed (parent 2026-07-31)

| Claim | Status |
|-------|--------|
| Steady-state drop sawtooth | **FALSIFIED** — 100% of drops by wall_s≈7; flat thereafter |
| H-DROP (offset set by startup drop count) | **REJECTED** — 12-drop and 18-drop same HDMI cluster (0.7 ms); pred −446.8 vs meas −196.0 |
| `av_drift_ms` / `clock=av-lock` as lip-sync | **BLIND** — five runs mean drift ≈ −30 ms identical; HDMI offsets two clusters ~116 ms apart |
| w-cpu dLead≈127 ↔ parent Δoffset 119 | **MISS PUBLISHED** — was an untested link; do not rebuild |

**Lip-sync criterion (binding):** `tools/avsync_measure_hdmi.py` only.  
`av_drift_ms` is servo telemetry inside `AV_PRESENT_LEAD_MS` deadband — never a soak PASS.

## Parent silicon facts (drop count)

| run | drops by ~7 s | drops at ~360 s | residual | publish_misses |
|-----|---------------|-----------------|----------|----------------|
| 1   | 15            | 15 (flat)       | 0        | 0              |
| 2   | 12            | 12 (flat)       | 0        | 0              |

HDMI offset clusters are a **separate** phenomenon (not explained by drop count).

## 1. Every path that increments `drops`

Sole site — deliberate pacer skip:

```
media_player.cpp: if (!present) droppedFrames_.fetch_add(1);
present = (avDecide(drift, leadMs, dropMs, dropRun) != Drop);
avDecide: Drop iff dropMs>0 && drift>dropMs && dropRun<maxDropRun (default 1)
```

Defaults: `resyncDropMs_=80`, lead ~40 (`AV_PRESENT_LEAD_MS`), `maxDropRun=1`.

**Not** `drops`: ffmpeg under-production, publish misses (`publishMisses_`).

Counters reset per stream (`droppedFrames_.store(0)` near play start).

Gate sites (`audioStartGate_`): first video ~3436; hold timeout ~2245; skipRgb ~2543; no-audio ~2873.  
`audioActive_.store(true)` at top of `audioPump` (~2054).

## 2. What varies startup drop **count** (not HDMI offset)

```
drift = audibleClockMs(bytes, queued) - frameContentMs(frameIndex)
Drop when drift > 80
```

- `kFeedTargetBytes` = 19200 B = **100.0 ms** past-bias on first `writePacedChunk` (including hold-drain).
- `queuedBytes` starts −1 → submitted-byte clock until status sample.
- Hold buffer `held_ms = f(T_first_video)` — timing-sensitive.
- Drop freezes relative audio vs frameIndex; Present ~period → repay until drift≤80 → quiet.

Host model (DROP COUNT only):

| residual lead | drops |
|---------------|-------|
| 588 ms | 12 |
| 715 ms | 15 |
| Δlead 127 ms | ≈3×period geometry — **not** HDMI Δoffset |

Hold race unit: held 620→12, 745→15, 120→0.

## 3. Pre-register (drop count only)

| ID | Prediction | Falsify if |
|----|------------|------------|
| P1 | drops = f(residual lead); 12@~588, 15@~715 | equal first-drift/held but Δdrops≥3 |
| P2 | all drops before wall_s≈10 then flat | new drops after wall_s=30 |
| P3 | ideal hold (zero residual + no dump race) → drops≤2 | drops≥10 with both proven |

**Do not** predict HDMI offset from drop count (H-DROP rejected).

## 4. Unexplained (do not build on)

```
media_player.hpp:301  audioClockPpm_ = -638;  // feed trimmed
av_clock.hpp          audioClockMs hardcodes 48000  // pacer clock NOT trimmed
```

Asymmetry noted by parent — untested attribution.

## 5. Gates

```
make unit; echo "true rc=$?"   # expect 0
# test_avclock: PASS startup drop variance (drop COUNT model only; not lip-sync)
# CRITERION lip_sync=tools/avsync_measure_hdmi.py ONLY
# H_DROP_STATUS REJECTED
# MISS_PUBLISHED H-DROP
```
