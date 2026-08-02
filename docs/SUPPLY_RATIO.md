# supply_ratio — stream starvation metric (replaces blind av-lock)

## Why

Parent RCA (480p "frames dropped"): link 1.56 Mbit/s vs PMS floor 2000 kbit/s.
While the stream arrived at **less than half real time**, the daemon printed:

```
media: frames=798 vfps=10.9 pfps=6.24 audio_s=33.42 wall_s=72.58 audio=on
       clock=av-lock av_drift_ms=113 drops=345 … desync_risk=0
```

`clock=av-lock` and `desync_risk=0` hid the defect. The discriminating number:

| case | audio_s | wall_s | ratio |
|------|--------:|-------:|------:|
| STARVED | 33.42 | 72.58 | **0.460** |
| HEALTHY | 69.94 | 70.43 | **0.993** |

## Derivation (quoted from product code)

### `audio_s` — NOT a setpoint

```
// media_player.cpp ~4206-4207
const int64_t abytes = audioBytes_.load();
const double a_sec = static_cast<double>(abytes) / (48000.0 * 4.0);
```

`audioBytes_` increments **only** on MrAudio `::write` of PCM after the start
gate (`media_player.cpp` audioPump `audioBytes_.fetch_add`). Hold-buffered PCM
is not counted until released. **Not** pinned inside `AV_PRESENT_LEAD_MS`.
The pump paces writes toward wall-48 kHz, so under full supply `audio_s≈wall_s`;
under starved ffmpeg input, fewer bytes arrive and `audio_s` lags. That lag is
the signal. (Contrast: `av_drift_ms` is stored inside the Hold loop vs `leadMs`
and **is** a setpoint readout — S3 closed.)

### `wall_s` — session relative

```
// media_player.cpp ~4181-4183, t0 armed at first complete video (~4055)
const int64_t wall2 = duration_cast<milliseconds>(now - t0).count();
// wall_s = wall2 / 1000.0
```

`t0` / `sessionOriginMonoMs_` arm at A/V audio_release (first video frame).
Not process uptime. Startup before arm → no media line yet / NO-DATA.

### Interval (product field)

```
supply_ratio = d_audio_s / d_wall_s
src=d_audio_s/d_wall_s
```

Cumulative `audio_s/wall_s` is also printed as `supply_ratio_cum=…` and labelled
**cumulative** so it cannot be mistaken for the interval metric (vfps cumulative
lesson).

## Classification

| class | meaning | gate rc |
|-------|---------|--------:|
| `ok` | interval established and ratio ≥ ok_min | 0 |
| `starved` | interval established and ratio < ok_min | **2** (hard) |
| `NO-DATA` | startup / paused / audio off / no prev / bad Δ | **77** |

Default `ok_min=0.90` (`DEFAULT_ASSUMED`):
- healthy cluster ~0.993; starved cluster ~0.460
- >10% content deficit per wall second → ≥6 s missing after 60 s wall
- conf `SUPPLY_RATIO_OK_MIN` / env `MISTERPLEX_SUPPLY_RATIO_OK_MIN` → `caller_supplied`

## What `clock=av-lock` and `desync_risk` actually were

### `clock=av-lock` — REMOVED

Was a **hardcoded string literal** at the old media line. Always the same.
Every historical "av-lock sustained" claim is void. Product now emits:

```
clock_master=audio|wall
clock_master_src=audibleClockMs_audioBytes_minus_queued | steady_since_t0_first_video
clock_av_lock=REMOVED_was_hardcoded_literal
```

### `desync_risk` — pipe geometry, NOT A/V

```
// ffmpeg_vf.hpp pipeDesyncRisk:
// identity_skip && producer_frame_bytes != reader_frame_bytes
```

Detects rawvideo pipe phase-walk risk when identity_skip trusts a coded size
that the measured delivery disagrees with. **Fit for pipe geometry only.**
Printed 0 throughout the bitrate-starved session because that defect is not a
pipe byte mismatch. Product now pins the scope on the media line:

```
desync_risk=0
desync_risk_der=pipeDesyncRisk_identity_skip_and_producer_bytes_ne_reader
desync_risk_scope=raw_pipe_geometry_NOT_av_supply
```

## Host red-before-green (already proven)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
make "$PWD/build/test_supply_ratio"
"$PWD/build/test_supply_ratio"; echo "true rc=$?"
# expect: PASS RED starved gate rc=2 … PASS GREEN healthy … true rc=0
```

## Parent — after deploying a daemon built from this branch

```bash
# During / after a cast, score the live log:
source tools/avsync_live_log_resolve.inc.sh   # if available
# or: LOG=/media/fat/misterplex_v2/misterplexd.log
python3 tools/score_supply_ratio_log.py "$LOG" --any-starved
echo "true rc=$?"
# STARVED session (bitrate > link): expect supply_ratio_class=starved, true rc=2
# HEALTHY (bitrate lowered):        expect class=ok, true rc=0
# Old daemon without field:         scorer reconstructs from audio_s/wall_s pairs
```

### Pre-registrations

| ID | Prediction |
|----|------------|
| SR1 | Starved cast (2000 kbps on 1.56 M link): ≥1 `supply_ratio_class=starved`, scorer rc=2 |
| SR2 | Healthy cast (bitrate ≤ link): last class=ok, scorer rc=0 |
| SR3 | media: line contains `src=d_audio_s/d_wall_s`, never bare `clock=av-lock` |
| SR4 | `desync_risk_scope=raw_pipe_geometry_NOT_av_supply` present |
| SR5 | First ~1 s after play: `supply_ratio=NO-DATA` reason=no_prev\* (not 0.0) |

## Files

- `host/libmisterplex/supply_ratio.hpp` — pure compute + format
- `arm/misterplexd/media_player.cpp` — media: line emit
- `tests/unit/test_supply_ratio.cpp` — red-before-green
- `tools/score_supply_ratio_log.py` — parent log scorer
