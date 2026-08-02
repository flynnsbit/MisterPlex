# RCA — real-content 480p drops (rk=9 BBB) — not CPU-bound

**Lane:** w-cpu · **No device access** · Parent-measured reproduction accepted as ground truth.  
**Daemon under test:** `9ce2c2d1` · conf `DDR_YUV_FORCE_SCALE=1` `DECODE=624x480` `PRESENT=fpga`.

## PRE_REG (before further parent measures) — publish misses

| ID | Prediction | Numbers | Falsifier |
|----|------------|---------|-----------|
| **P0** | `presents+=48` log step is **log cadence**, not a rate gate | every log when `presentCount_%48==0` | source lacks `% 48` |
| **P1** | Loop is **serial** read→pace→present; pfps\<vfps is **Drop branch**, not a second clock | `maxDropRun=1` → at most one drop then forced Present attempt | drop lines show multi-drop runs without presents |
| **P2** | **Positive `av_drift_ms`** = audio ahead of *paced frame* (video behind); healthy −21..−40 is **servo deadband near −lead**, not “good lipsync” | `avDrift=audioMs−frameMs`; Hold iff `drift+lead<0` | source differs |
| **P3** | Collapse variable is **GEOMETRY/rescale** more than “real content” | **rk=27** (624×480 FullBleed) **healthy** like rk=6: `vfps≥22`, `pfps≥22`, drops front-loaded then flat | rk=27 also `vfps≲15` + climbing drops |
| **P4** | On rk=9, budget is **read-side (scale/decode)** and/or **pace Drop**, not DDR copy ms | with `PRESENT_PROFILE=1`: `read_us_f + read_eagain_sleep_us_f` dominates `ddr_total_us_p` | `ddr_total_us_p` ≳ 80 000 and read small |
| **P5** | Pipe back-pressure **possible** (ffmpeg write blocks → low ffmpeg CPU) **iff** consumer loop \< produce capability; **not proven** until FIONREAD/wchan | see sampler | FIONREAD~0 and ffmpeg wchan≠pipe_write while collapsing |

## 1. What gates present? (quoted)

### 1a. The “+48 presents” smell — **LOG ONLY**

```3818:3824:arm/misterplexd/media_player.cpp
                    if ((presentCount_ % 48) == 0) {
                        log(std::string("media: fpga frame_tx ok via ") +
                            "DDR" +
                            " presents=" + std::to_string(presentCount_) +
                            " frames=" + std::to_string(frameIndex) +
                            " ms=" + std::to_string(static_cast<int>(fpga_.lastPushMs())));
                    }
```

**Finding (source):** interval between those lines = wall time for **exactly 48 successful presents**. At pfps≈8 that is ~6 s. It is **not** a fixed-rate gate of +48/s.

### 1b. Real loop (serial)

```3929:4214:arm/misterplexd/media_player.cpp
// while (!stop):
//   read until frameBytes (O_NONBLOCK; EAGAIN → sleep 2ms)   // ~3914–3994
//   ++frameIndex
//   clockMs = audibleClockMs(audioBytes, audioQueued) or wall
//   drift = avDriftMs(clockMs, frameMs)   // audio − frame content
//   avDecide → Hold (sleep 2ms) | Drop | Present
//   if Present: presentCleanFrame → publishDdrFrame
```

Reader is **non-blocking** (`F_SETFL|O_NONBLOCK` at ~3377–3379). Empty pipe → EAGAIN + **2 ms sleep**, not a blocking `read`.

### 1c. Pace decision (the actual “gate”)

```29:32:host/libmisterplex/av_clock.hpp
// drift = audio − frame content
//   drift < 0  video ahead → hold
//   drift > 0  video behind → drop to catch up
```

```269:276:host/libmisterplex/av_clock.hpp
inline AvAction avDecide(int64_t driftMs, int64_t leadMs, int64_t dropMs, int dropRun,
                         int maxDropRun = 1) {
    if (dropMs > 0 && driftMs > dropMs && dropRun < maxDropRun)
        return AvAction::Drop;
    if (driftMs + leadMs < 0)
        return AvAction::Hold;
    return AvAction::Present;
}
```

Default product: `lead_ms` conf (`AV_PRESENT_LEAD_MS`, often 40), `resync_drop_ms` 80 (`kDefaultResyncDropMs`).

**`maxDropRun = 1`:** at most **one** Drop, then next late frame must **Present** (or Hold). Prevents drop storms; while chronically behind you get **Drop/Present interleave** → pfps can sit well below vfps while drops climb. Matches parent ledger `frames ≈ presents + drops`.

### 1d. DDR push is not a fixed 8 Hz clock

`sendDdrFrame` may PLXD-wait up to 50×1 ms (`fpga_spi.cpp` kPlxdPollMaxIters) or 1.5 ms bank-reuse sleep on absent path. Parent push **ms=4..20** is lastPushMs — **not** full loop period. Full period = read + hold sleeps + present (DDR+overlay).

## 2. Positive drift (why sign flipped)

```cpp
avDriftMs = audioMs - frameMs;  // paced frameIndex, not presentCount
```

| Regime | Typical `av_drift_ms` | Meaning |
|--------|----------------------|---------|
| Healthy lock | **−lead … 0** (parent −21..−40 with lead=40) | Servo deadband — Hold keeps video slightly ahead of “need” (`av_clock.hpp` A5 comment: **not lipsync PASS**) |
| rk=9 collapse | **+96…+215** | Audio heard **ahead** of content time of frame being decided → video **late** → Drop when `> dropMs` |

Display path (does not free-heal on drops): `av_display_offset_ms = avDrift(audio, frameContentMs(presentCount))` — larger positive when pfps≪ content rate.

**Hypothesis (not finding):** audio wall-realtime advances; video loop cannot complete 24 frames/s of (scale+read+present); drift goes positive and stays there.

## 3. Pipe back-pressure — prove or kill

| Side | Mechanism | Observable |
|------|-----------|------------|
| ffmpeg write | default **blocking** write to pipe | wchan ~`pipe_write` / state S; CPU low while “working” |
| daemon read | **NONBLOCK** + 2 ms EAGAIN sleep | `read_eagain_*` in `PRESENT_PROFILE`; high sleep ⇒ **under-fed** (producer slow or empty) |
| pipe capacity | default target 2 MiB (~4.7×449280) | log `raw_video_pipe` actual; full pipe ⇒ producer blocks |

**Interpretation matrix (PRE_REG P4/P5):**

| read_eagain_sleep | ddr_total / present | ffmpeg wchan | Verdict class |
|-------------------|---------------------|--------------|---------------|
| high | low | running / ffmpeg | **producer/scale limited** (not BP) |
| low | high | pipe_write | **consumer/present BP** (hypothesis) |
| high | high | mixed | both — need rates |

Always-on without profile: count `A/V resync drop` rate; `av_hold_first_10s av_hold_wait_ms`; pipe sampler tool below.

## 4. Geometry vs content — **rk=27 split** (parent runs)

| Asset | Geometry | Rescale under FORCE_SCALE=1 | Role |
|-------|----------|-----------------------------|------|
| rk=6 | 624×480 synthetic | crop/pad or light path; identity-class | **CONTROL healthy** (parent: 23.4/23.2) |
| rk=9 | 624×352 BBB | `scale`→618×480 + pad (`arm_rescale=1`) | **FAIL** (parent) |
| rk=27 | 624×480 FullBleed real motion 1200 s | same bank as rk=6 | **SPLIT** |

### PRE_REG outcomes

- **GEOM/rescale wins (P3 hit):** rk=27 like rk=6 — `vfps≥22`, `pfps≥22`, drops flat after ≤~30 startup; GEOM log `identity_skip` or no heavy V scale.
- **CONTENT wins (P3 miss):** rk=27 collapses — `vfps≲16`, drops climbing, positive drift — then decode/complexity, not 352→480 scale alone.
- **Mixed:** rk=27 mild loss (vfps 20–22) — soft GEOM tax + content.

## 5. Parent commands (read-only / conf-safe)

### A. rk=27 split (critical path) — after cast rk=27 ≥60 s

```sh
# On device. Resolve live root (two-roots).
ROOT=$(sh -c 'for d in /proc/[0-9]*; do e=$(readlink -f "$d/exe" 2>/dev/null)||continue; b=$(basename "$e"); [ "$b" = misterplexd ]||continue; dir=$(dirname "$e"); case $(basename "$dir") in bin) dirname "$dir";; *) echo "$dir";; esac; break; done')
L=${ROOT:-/media/fat/misterplex_v2}/misterplexd.log
echo "ROOT=$ROOT LOG=$L"
# Session tail: last play banner → now
grep -E 'content fps=|GEOM |vfps=|A/V resync drop|av_hold_first_10s|fpga frame_tx ok|MEASURED_FPS|arm_rescale|identity_skip|present_profile|raw_video_pipe' "$L" | tail -n 200
# Score last telemetry line (manual): vfps pfps drops av_drift_ms wall_s
grep 'vfps=' "$L" | tail -n 5
echo "true rc=0"
```

**PRE_REG record after run:** write `P3=HIT|MISS` with quoted vfps/pfps/drops.

### B. rk=9 budget without new binary (always-on fields)

```sh
L=.../misterplexd.log   # same ROOT resolve
# Hold budget first 10s
grep 'av_hold_first_10s' "$L" | tail -n 3
# Drop storm rate: count resync drops in last play
grep 'A/V resync drop' "$L" | tail -n 40
# Cadence of present log (Δpresents fixed 48 — check Δwall via timestamps if present)
grep 'fpga frame_tx ok' "$L" | tail -n 10
echo "true rc=0"
```

### C. PRESENT_PROFILE (optional conf — **only if parent accepts conf edit + atomic restart**)

Add `PRESENT_PROFILE=1` (or conf key already wired in `main.cpp:382`), stage conf, restart daemon **without** scp-over-live-binary. Then cast rk=9 ≥30 s and:

```sh
grep 'present_profile' "$L" | tail -n 5
```

Compare `read_us_f`, `read_eagain_sleep_us_f`, `pacing_wait_us_f`, `ddr_total_us_p` (µs **per frame/present** as labelled).

### D. Live pipe back-pressure sampler (no daemon rebuild)

From repo on device or scp tools only:

```sh
WINDOWS=10 WINDOW_S=2 sh tools/pipe_backpressure_sample.sh
echo "true rc=$?"
```

### E. Offline log budget helper (host or device)

```sh
sh tools/present_loop_budget_from_log.sh /path/to/misterplexd.log
echo "true rc=$?"
```

## 6. Hypothesis status (Rule 0)

| Claim | Status |
|-------|--------|
| Not ARM CPU saturation | **Parent measured** — accepted |
| Push ms not limiter | **Parent measured** + source lastPushMs is copy path only |
| +48 = fixed present gate | **KILLED by source** (`% 48` log) |
| ffmpeg blocked on pipe is root cause | **HYPOTHESIS** — needs FIONREAD/wchan +/or present_profile |
| GEOM/rescale is the split variable | **HYPOTHESIS P3** — rk=27 settles |
| Positive drift = video behind audio clock | **Source definition** + parent sign |

## 7. What we will **not** do

- No device SSH/deploy from this lane.
- No weakening drop detection or “make ERROR soft” without proof.
- No publishing “present is vsync-locked to 8 Hz” — **not in source**.
