# Steady-state A/V pacer drops — source RCA + discriminator

**Lane:** w-fit · **NO DEVICE** · Rule 0: quoted code only for mechanism.  
**Parent finding (measured HW):** 360s 480p EOF session  
`frames=8639 presents=8614 drops=25 residual=0`; 13 startup burst;  
**12 steady-state drops / ~358 s ≈ one per ~30 s.**  
Drop only when `drift > resyncDropMs` (80). Therefore internal control error
crossed **+80 ms** twelve times in steady state.

---

## 1. What `av_drift_ms` is (and is not)

**Not** lip-sync to the room. **Is** the pacer control input.

```22:40:host/libmisterplex/av_clock.hpp
inline int64_t frameContentMs(int64_t frameIndex, int num, int den) {
    ...
    return (frameIndex * 1000LL * static_cast<int64_t>(den)) / static_cast<int64_t>(num);
}
inline int64_t audioClockMs(int64_t audioBytes) {
    return (audioBytes * 1000LL) / (48000LL * 4LL);
}
// drift = audio clock − content time of the frame about to be shown.
inline int64_t avDriftMs(int64_t audioMs, int64_t frameMs) { return audioMs - frameMs; }
```

Product path uses **audible** master clock (submitted − ring queued), not raw submit:

```76:82:host/libmisterplex/mraudio_status.hpp
inline int64_t audibleClockMs(int64_t writtenBytes, int64_t queuedBytes) {
    int64_t played = writtenBytes;
    if (queuedBytes >= 0)
        played -= queuedBytes;
    ...
    return (played * 1000LL) / kMrAudioBytesPerSec;  // kMrAudioBytesPerSec = 48000*4 NOMINAL
}
```

Present loop (quoted):

```3120:3168:arm/misterplexd/media_player.cpp
// frameMs = content schedule + OSD offset
const int64_t frameMs =
    frameContentMs(frameIndex, fpsNum, fpsDen) + avOffsetMs_.load();
...
clockMs = misterplex::audibleClockMs(audioBytes_.load(), audioQueuedBytes_.load());
// else wall steady_clock if no audio
const int64_t drift = misterplex::avDriftMs(clockMs, frameMs);
const AvAction act = avDecide(drift, leadMs, dropMs, dropRun);
...
if (!present) {
    ++dropRun;
    droppedFrames_.fetch_add(1);
} else {
    dropRun = 0;
    presentCleanFrame(...);
}
```

**Accumulation in words:**

| Side | Quantity | Advances when |
|------|----------|----------------|
| Master `clockMs` | `audibleClockMs(written, queued)` | MrAudio **plays** bytes (written↑, queued held by servo) converted at **nominal** 192000 B/s |
| Slave `frameMs` | `frameContentMs(frameIndex,fps)+avOffset` | Each decoded raw frame increments `frameIndex` (drop **or** present) |
| `drift` | `clockMs - frameMs` | **+** means master past schedule → video **behind** → may Drop |

It is **not** wall-clock vs audio-bytes alone, and **not** PTS vs PTS. It is  
**audible-byte-time (nominal 48 kHz) − rational content time of frameIndex**.

`avOffsetMs_` is a constant OSD trim — shifts the band, does **not** ramp.

---

## 2. Drop decision and `maxDropRun=1`

```58:64:host/libmisterplex/av_clock.hpp
inline AvAction avDecide(int64_t driftMs, int64_t leadMs, int64_t dropMs, int dropRun,
                         int maxDropRun = 1) {
    if (dropMs > 0 && driftMs > dropMs && dropRun < maxDropRun)
        return AvAction::Drop;
    if (driftMs + leadMs < 0)
        return AvAction::Hold;
    return AvAction::Present;
}
```

Defaults: `presentLeadMs_=40`, `resyncDropMs_=80` (`media_player.hpp`).

Unit test locks consecutive-drop cap:

```67:71:tests/unit/test_avclock.cpp
CHECK(avDecide(200, lead, drop, 0) == AvAction::Drop);
CHECK(avDecide(200, lead, drop, 1) == AvAction::Present);  // dropRun>=max → forced Present
```

### Residual after a drop — **NOT a full reset**

On Drop:

1. `frameIndex` was already `++` before pacer (`media_player.cpp` ~3118).
2. Frame is **not** presented; **next** loop reads next frame and does `++frameIndex` again.
3. Next `frameMs` is one frame period later: at 24/1, **T = 1000/24 ≈ 41.667 ms**.
4. `clockMs` does **not** jump backward.

So if drop fires at drift ≈ D (D > 80):

```
drift_after ≈ D - T_frame ≈ D - 41.667 ms
```

**Example:** D = 81 → after ≈ **39.3 ms** (Present; under 80).  
**Not** reset to 0. Parent’s “80 ms every 30 s ⇒ 2.67 ms/s” assumes full clear — **that model is false in source.**

Correct ramp model if drops fire just above threshold and only one frame is shed:

```
Δdrift per drop ≈ T_frame ≈ 41.667 ms
inter-drop period τ ≈ T_frame / R     where R = drift ramp rate (ms content-second)
R ≈ 41.667 / τ
```

For **τ ≈ 30 s**: **R ≈ 1.39 ms/s ≈ 1390 ppm** (of the content second), **not** 2667 ppm.

### Consistency with **12 isolated** drops

With `maxDropRun=1`, a **large** stall (e.g. +200 ms) yields: Drop once (−41.7), then **forced Present** even if still >80, then Drop on a later frame → **clusters / every-other-frame** catch-up until D < 80.

**Isolated** singles every ~30 s imply each crossing only needs **one** frame shed ⇒ peak only slightly above 80 (roughly 80–120 ms), not multi-frame catch-up storms. That fits:

- **(A)** slow ramp to ~80, drop to ~38, ramp again, **or**
- **(B)** rare single stalls of ~80–120 ms, Poisson in time.

It does **not** fit a sustained multi-hundred-ms backlog without clusters (unless stalls are brief).

---

## 3. Class (A) rate mismatch — is ~2667 ppm / ~1390 ppm plausible?

### `audioClockPpm_` (feed seed only)

```1984:1984:arm/misterplexd/media_player.cpp
const double kBytesPerSec = 48000.0 * 4.0 * (1.0 + audioClockPpm_ / 1000000.0);
```

Default **−638** (`media_player.hpp:281–288`): seed for `feedRateBytesPerSec` servo;  
comment: FPGA plays **slower** than nominal; old +685 inverted sign.

```132:145:host/libmisterplex/mraudio_status.hpp
// servo holds ring depth; converges true drain rate
inline double feedRateBytesPerSec(double nominalBytesPerSec, int64_t queuedBytes) { ... }
```

**Critical:** `audibleClockMs` converts played bytes with **nominal** `48000*4`, **ignoring** ppm.  
Servo holds depth ⇒ `d(played)/dt ≈ true FPGA drain bytes/s`.  
If FPGA is −638 ppm slow, audible “ms” advance **slower than wall** → drift tends **negative** → **Hold**, not Drop.

So the **calibrated −638 ppm trim does not by itself predict +80 ms Drop sawteeth.**  
A Drop sawtooth needs master **fast** vs content schedule (or content frames **late**).

| ppm magnitude | Meaning | Plausible? |
|--------------:|---------|------------|
| ~20–100 | crystal | yes |
| **638** | lab-measured FPGA audio vs nominal (in-tree) | yes (measured comment) |
| **~1001** | 24.000 vs 23.976 content | yes if wrong rate — **parent forbids**: assets are 24.000 |
| **~1390** | R for τ=30 s with **partial** reset (−T) | large vs crystal; **possible** as residual schedule/audio basis error; **not** explained by default −638 alone |
| **~2667** | R if full 80 ms reset (false model) | **too large** for crystal; would need ~0.27% rate error; **do not use** as A’s required ppm |

**Class A is not ruled out by ppm size at 1390**, but **is not supported by the −638 feed trim** as the direct cause.  
`av_clock.hpp:54–57` **claims** forced CFR ⇒ drift only from stalls — that is a **design intent**, not a proof; A remains open until intervals + drift-at-drop series decide.

**Unknown — check:** log `drift_ms` on every drop line (already partially logged every 24th drop) and `audio_s` vs `frameContentMs(frameIndex)/1000` slope over 360 s.

---

## 4. Class (B) sporadic stalls

Positive drift when **frames arrive late** while audible clock keeps advancing (decode/CPU/pipe/PMS).  
One stall ≳80 ms → one Drop if peak < 80+T; larger → drop clusters.

**Falsifier:** irregular intervals (see §5).

---

## 5. Discriminator (ready for parent’s timestamps)

n ≈ 12 intervals/run, N ≈ 36 across 3 runs. Low power — pre-register soft thresholds; combine runs.

### Primary: CV of inter-drop intervals

Let Δt_i = t_{i+1}−t_i (steady-state only; **exclude startup burst**).

```
CV = stdev(Δt) / mean(Δt)
```

| Hypothesis | Pre-registered CV | Mean Δt (if A + partial reset @24fps) |
|------------|-------------------|----------------------------------------|
| **(A) regular ramp** | **CV ≤ 0.25** (prefer ≤0.15 if clean) | ~25–35 s if R~1.2–1.7 ms/s |
| **(B) Poisson** | **CV ≥ 0.75** (exponential CV=1) | mean whatever; memoryless |
| **Inconclusive** | 0.25 < CV < 0.75 | need more runs / secondary tests |

### Secondary: Fano factor on counts

Bin steady-state time into K bins of width w ≈ mean(Δt) (e.g. 30 s).  
n_k = drops in bin k.  
`F = var(n) / mean(n)`.

| Class | Expect F |
|-------|----------|
| (A) regular | **F ≪ 1** (sub-Poisson), often &lt; 0.4 |
| (B) Poisson | **F ≈ 1** (0.7–1.3 at small n) |

### Tertiary: KS / exponential

On pooled Δt: empirical CDF vs Exp(λ=1/mean).  
At n=12, KS is weak; use as support only.  
**(B) pre-reg:** D small, p not tiny. **(A) pre-reg:** mass near one lag, rejects Exp.

### Quaternary: lag-1 autocorrelation of Δt

**(A):** ρ₁ ≈ 0 (metronome) or slight. **(B):** ρ₁ ≈ 0 too (memoryless) — **does not separate**; skip as primary.

### What to compute (exact)

Parent provides CSV `t_s` or `wall_ms` per drop (steady-state). Then:

```bash
python3 scripts/analyze_drop_intervals.py drops_run1.csv drops_run2.csv drops_run3.csv
```

Script prints mean, stdev, CV, Fano(w=mean), KS vs Exp, verdict vs thresholds above.

### Pre-registered expectation (w-fit, before seeing intervals)

| If true mechanism | Expect |
|-------------------|--------|
| (A) slow rate mismatch | CV **&lt; 0.25**, Fano **&lt; 0.4**, mean Δt stable across 3 runs within ~20% |
| (B) stalls | CV **&gt; 0.75**, Fano **~1**, means may wander run-to-run |
| Mixed / threshold chatter | CV mid; inspect drift_at_drop series |

**I do not pre-claim A or B.** Interval CV is the decider.

---

## 6. Periodic ~30 s path disturbances (source sweep)

| Candidate | Period | Verdict |
|-----------|--------|---------|
| PMS x264 GOP `keyint=50` @24fps | **~2.1 s** | not 30 s (`docs/pms-baseline-profile.md`) |
| `skipForwardMs_ = 30000` | 30 s | **user skip only**, not autonomous |
| Feed servo `kFeedServoTauSec = 8` | ~8 s | depth loop; not drop metronome by itself |
| Audio latency log every 5 s | 5 s | log only |
| OSD poll ~100 ms | — | avOffset step changes could step drift; not 30 s unless user |
| HLS/segment boundary | often 4–10 s | **unknown** for this PMS ladder — check transcoder segment duration on device |
| Ring target 100 ms | — | steady |

**No in-daemon 30 s timer** found that drops frames.  
**Unknown — check:** PMS transcode segment length and keyframe log alignment vs drop times; CPU spikes in 1 Hz sampler.

---

## 7. Implications for the user complaint

- Startup 13 drops (odd frames) are a **separate** burst — do not mix into CV.  
- Steady **12 isolated** drops/6 min = **deliberate pacer destroys** when control error &gt;80 ms.  
- Each destroy sheds **~1 frame (41.7 ms)**, not a full resync to zero.  
- Fix direction **after** discriminator:  
  - **(A)** find rate basis error (audible nominal vs content; confirm fps filter; long-window slope `clockMs` vs `frameMs`).  
  - **(B)** find stall source (decode, read pipe, present).  
  - Either way: consider logging **every** drop with `drift_ms,frameIndex,clockMs,frameMs` (today every 24th drop only: `media_player.cpp:3171`).

---

## 8. Parent commands (device — you run)

```bash
# After capturing drop timestamps (one epoch-seconds or ms per line):
python3 scripts/analyze_drop_intervals.py /path/run1.txt /path/run2.txt /path/run3.txt

# On live 1 Hz lines, prefer fields already present:
#   av_drift_ms= drops= audio_s= wall_s= dframes= dpresents=
# Optional: raise drop log rate temporarily is a CODE change — ask before patch.
```

Confirm session log contains `content fps=24/1` and `AUDIO_CLOCK_PPM=...` and `AV_RESYNC_DROP_MS=80`.
