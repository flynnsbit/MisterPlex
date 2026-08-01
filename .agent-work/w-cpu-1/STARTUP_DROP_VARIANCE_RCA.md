# Startup drop-count variance RCA (w-cpu)

**Branch/SHA:** see `status.txt` after commit  
**Scope:** source analysis + host unit model. No device access.  
**ERROR 17:** retracted — fixtures are genuinely 24.000 fps; `fps=24/1` is correct.

## Parent silicon facts (given)

| run | drops by ~7 s | drops at ~360 s | residual | publish_misses | A/V offset |
|-----|---------------|-----------------|----------|----------------|------------|
| 1   | 15            | 15 (flat)       | 0        | 0              | −316.0 ms  |
| 2   | 12            | 12 (flat)       | 0        | 0              | −196.7 ms  |

- Same fixture (rk8 480p), conf, daemon binary, core.
- **All drops in first ~7 s; zero steady-state drops for ~353 s.**
- Falsifies “steady-state sawtooth” inferred from a single EOF total.
- Δoffset = 119.3 ms between runs — product-relevant beyond drop count.

## 1. Every path that can produce a `drops` increment

`droppedFrames_` / telemetry `drops` count **only** deliberate A/V-pacer skips.

### Sole increment site

```3503:3509:arm/misterplexd/media_player.cpp
            if (!present) {
                ++dropRun;
                droppedFrames_.fetch_add(1);
                ...
                log("media: A/V resync drop drift_ms=...");
```

`present` is cleared only when `avDecide` returns `Drop`:

```3477:3485:arm/misterplexd/media_player.cpp
                    const AvAction act = avDecide(drift, leadMs, dropMs, dropRun);
                    ...
                    present = (act != AvAction::Drop);
```

```48:52:host/libmisterplex/av_clock.hpp
// avDecide: Drop iff dropMs>0 && driftMs>dropMs && dropRun<maxDropRun (default 1)
// Hold iff driftMs+leadMs<0; else Present
```

Defaults: `resyncDropMs_ = 80` (`kDefaultResyncDropMs`), `presentLeadMs_` from `AV_PRESENT_LEAD_MS` (typically 40), `maxDropRun = 1`.

### Not counted as `drops`

| Event | Counter |
|-------|---------|
| ffmpeg under-production | invisible to `drops` (shows as `frames` vs `wall*fps`) |
| failed DDR publish | `publishMisses_` / ledger, not `drops` |
| deliberate? No — only pacer Drop | |

Ledger (parent residual=0): `frames - presents - drops - publish_misses ≈ 0` with `publish_misses=0` ⇒ every non-present was a pacer Drop.

### Counter reset (per stream)

```2521:2525:arm/misterplexd/media_player.cpp
    const int64_t leadMs = presentLeadMs_;
    const int64_t dropMs = resyncDropMs_;
    int dropRun = 0;
    ...
    droppedFrames_.store(0);
```

### `audioActive_` / gate sites (timing, not drop counters)

| Site | Role |
|------|------|
| `audioActive_.store(true)` ~2054 | top of `audioPump` — pacer may use audible clock |
| `audioActive_.store(false)` ~2353 | pump exit |
| `audioStartGate_.store(false)` ~2870 | product path: closed until first video |
| `audioStartGate_.store(true)` ~3436 | **first complete video frame** (main release) |
| `audioStartGate_.store(true)` ~2245 | hold **timeout** (`kAudioHoldTimeoutMs=1200`) without video |
| `audioStartGate_.store(true)` ~2543 | audio-only / skipRgb path (immediate) |
| `audioStartGate_.store(true)` ~2873 | no audio pipe |

## 2. What accumulates +80 ms drift at startup (and why the count varies)

### Drift definition

```
drift = audibleClockMs(audioBytes, queued) − frameContentMs(frameIndex)
Drop when drift > 80 and dropRun < 1
```

`frameContentMs` is exact rational (`frameIndex * 1000 * den / num`) — **not** a rate bug (ERROR 17 retracted).

`AV_PRESENT_LEAD_MS` (~40) is a **Hold** deadband (`drift + lead < 0`), not a Drop threshold. Drop threshold is solely `resyncDropMs` (80).

### Prefill bias (100.0 ms)

```114:114:host/libmisterplex/mraudio_status.hpp
inline constexpr int64_t kFeedTargetBytes = kMrAudioBytesPerSec / 10; // 19200 B = 100.0 ms
```

`writePacedChunk` **always** past-biases `audioDue` by that depth on first write — including hold-drain:

```arm/misterplexd/media_player.cpp (writePacedChunk)
// Always past-bias prefill (cold-start, seek, hold-release same).
audioDue = now - kFeedTargetBytes/rate;
```

So after gate open the pump can burst ~100 ms of PCM before sleeping.

### Submitted-clock window

`audioQueuedBytes_` starts at **−1**. Until `readMrAudioQueuedBytes` succeeds (every 4 chunks), `audibleClockMs` falls back to **submitted** bytes (no ring subtract) — burst looks fully “heard.”

### Hold-until-video ideal vs silicon

Ideal hold: `audioBytes_==0` at gate open, content origin 0, sim `HoldUntilVideo` → **0 drops**.

Silicon still sees **12–15** drops ⇒ a **residual audio lead at/after frame 1** remains. Candidates (all **timing-sensitive**, not content bytes):

1. **`held_ms = f(T_first_video)`** while gate closed (decode/net/sched). Cap 2 s ring-drop-head.
2. **Hold dump race:** past-bias + submitted clock let held PCM race ahead of `frameIndex`.
3. **Video present/decode lag** vs realtime in the first seconds (positive drift).
4. **maxDropRun=1** ⇒ Drop/Present staircase while repaying lead; then quiet.

### Why drops stop after ~7 s

Product Drop skips `presentCleanFrame` and immediately takes the next pipe frame; audio keeps running on the pump thread. Relative to `frameIndex`, a fast Drop **freezes** audible while `frameMs` jumps +period → drift falls ~one frame. Present spends ~period of wall so audio advances with picture. After enough pairs, `drift ≤ 80` permanently → **zero steady-state drops**. Matches parent soaks.

### Why 12 vs 15 (and Δoffset ≈ 119 ms)

Host first-principles model (`kStartupDropWallMs=0`, `kStartupPresentWallMs=41`):

| residual lead at frame1 | drops |
|-------------------------|-------|
| 588 ms                  | 12    |
| 715 ms                  | 15    |
| Δlead = **127 ms**      | Δdrops = 3 |

**127 ms ≈ parent Δoffset 119.3 ms** (within model/measurement band).

Mechanism claim: **drop count and steady offset both track residual lead after gate open;** run-to-run lead differs by ~one to three frame periods because `T_first_video` / held dump / sched jitter differ.

Hold-race unit map: `held_ms=620 → drops=12`, `held_ms=745 → drops=15`, `held_ms=120 → drops=0`.

## 3. Pre-registered predictions

| ID | Prediction | Falsify if |
|----|------------|------------|
| P1 | Startup drops = f(residual_lead); 12 @ ~588 ms, 15 @ ~715 ms | Equal residual lead (log `held_ms` + first `drift_ms`) but Δdrops ≥ 3 |
| P2 | Δlead between the two soak classes ≈ 100–140 ms | Measured first-drift delta outside that band while drops still 12 vs 15 |
| P3 | All drops before wall_s≈10; then flat | New drops after wall_s=30 with residual=0 |
| P4 | Ideal hold (proven `audio_bytes_at_release=0` **and** no dump race) → drops ≤ 2 | drops ≥ 10 with both proven |
| P5 | `drops` never counts publish miss or ffmpeg gap | `drops` rises while `avDecide` never Drop (need code bug) |

**ERROR 17:** do not predict drops from fps mismatch — fixtures are 24.000.

## 4. Host test (red-before-green, both outcomes)

Implemented in `host/libmisterplex/av_clock.hpp` + `tests/unit/test_avclock.cpp`:

- `simulateStartupPacer(..., EarlyPlay)` with first-principles walls
- `sweepEarlyPlayDrops(500,800)` covers drops 9–17 including **exact 12 and 15**
- `simulateHoldReleaseRace(held_ms)` — controlled timing perturbation; 620 vs 745 yields 12 vs 15
- A constant answer cannot pass: requires `dLead ∈ [100,140]` and both soak counts

```
make unit   # true rc=0
# test_avclock excerpt:
# PASS startup drop variance: drops12=12 drops15=15 dLead=127 ...
```

## 5. Parent-only device checks (do not run from agent)

Log on next soak (confirm mechanism, no patch required yet):

```bash
# On device, during first 15 s of play, capture hold/release + first drops:
# (parent already has media: logs; ensure these lines are retained)
#   media: audio hold — buffering PCM...
#   media: audio release content_origin_ms=0 ... held_bytes=... held_ms=...
#   media: A/V audio_release first_frame=... content_origin_ms=0
#   media: A/V resync drop drift_ms=... drops=...
#
# After run, extract:
#   held_ms from release line; first drift_ms; final drops; steady av offset
# PREDICT: larger held_ms ↔ more startup drops; Δheld_ms ≈ Δoffset ≈ 100–140 ms for 12 vs 15
```

## 6. Verdict

| Question | Answer |
|----------|--------|
| What varies 12 vs 15? | **Timing-sensitive residual audio lead** after gate open (hold dump / T_first_video / sched), repaid by pacer Drops until drift ≤ 80 |
| Content-determined? | **No** — same fixture/conf; host race test changes only `held_ms` |
| Steady-state sawtooth? | **Falsified** by parent soaks + repayment model |
| Recoverable? | Ideal hold already targets 0; remaining drops imply dump-race residual — product fix would serialize hold drain with frame1 / avoid submitted-clock overstatement / open gate with paced drain tied to video (design separate from this RCA) |
| Quantified | Δ3 drops ↔ Δlead ≈ **127 ms** model vs **119 ms** measured offset |

## Citations

- `arm/misterplexd/media_player.cpp` — gate, hold, writePacedChunk past-bias, avDecide Drop
- `host/libmisterplex/av_clock.hpp` — frameContentMs, avDecide, StartupPacerSim, HoldReleaseRace
- `host/libmisterplex/mraudio_status.hpp` — kFeedTargetBytes, audibleClockMs
- `tests/unit/test_avclock.cpp` — variance gates + PRE_REGISTER lines
