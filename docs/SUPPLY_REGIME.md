# supply_regime — path-starved vs back-pressure

## Why `supply_ratio` alone is not enough

Parent 2026-08-02 hardware: while `supply_ratio`/`audio_s/wall_s` was **~0.63**,
solo playback used **~47 KB/s** on a path that could still carry a concurrent
bulk pull of **+60.6 KB/s** (total **~107.6 KB/s** = measured ceiling).

So low supply does **not** tell the operator whether:

1. **the source/path cannot deliver** (nothing arriving), or  
2. **we are not pulling** (our loop is the brake; path has idle capacity).

`supply_regime` is the **pipe-fill** companion (FIONREAD path vs back-pressure).
Parent silicon later **falsified local back-pressure** on the 480p collapse
(ffmpeg not in `pipe_write`, daemon in `pipe_read`, `recv_q=0`) — see
**[`docs/SUPPLY_STARVE_LOCUS.md`](SUPPLY_STARVE_LOCUS.md)** for the fuller
`starved_transport|consumer|unknown` classifier. Root-cause on Recv-Q stays
with **w-cpu-1** (do not duplicate).

## What the daemon can see (no root)

| signal | how | proves | does NOT prove |
|--------|-----|--------|----------------|
| `pipe_Bps` | `d(totalBytes)/d_wall` from rawvideo `::read` | post-decode frame bytes into present loop | HTTP octets / TCP goodput |
| `pipe_fill_peak` | `FIONREAD` peak / `F_GETPIPE_SZ` | empty ⇒ waiting on producer; full ⇒ we back-pressure ffmpeg | path capacity; other flows |
| `ffmpeg_rchar_Bps` | `/proc/<child>/io` `rchar` Δ | best-effort child read() volume | pure network; needs readable proc |
| path ceiling | — | — | **cannot** — needs external bulk-pull / host instrument |

Absence of a probe → **`NO-DATA`**, never `0.0` / never “empty means healthy”.

## Read chain (where a block can form)

Quoted product path (`media_player.cpp` STREAM=0 present loop):

1. `rfd` set **O_NONBLOCK** after pipe open.  
2. `while (got < frameBytes): n = ::read(rfd, …)`  
   - `EAGAIN` → sample `FIONREAD`, sleep **2 ms**, retry — **read itself does not block**.  
3. After a full frame: `avDecide` → **Hold(2 ms)** / **Drop** / `presentCleanFrame`.  
4. `presentCleanFrame` may take `presentMu_` and do **DDR publish** (ms-scale).

Back-pressure on ffmpeg’s stdout write is therefore **time spent outside read**
(Hold / present / lock), not a blocking `read()`. High `FIONREAD` peak ⇒
ffmpeg produced faster than that loop drained.

## Classification

| `supply_regime` | condition | gate rc |
|-----------------|-----------|--------:|
| `ok` | supply_ratio not starved | 0 |
| `starved_by_path` | starved + fill_peak &lt; 0.10 | **2** |
| `starved_by_backpressure` | starved + fill_peak ≥ 0.80 | **3** |
| `starved_ambiguous` | starved + mid fill or fill NO-DATA | **4** (hard, not 77) |
| `NO-DATA` | supply_ratio not established | **77** |

Defaults `fill_empty_max=0.10`, `fill_full_min=0.80` are `DEFAULT_ASSUMED`.

## Counters (citation fix)

| counter | increments | reset (this tree) | NOT |
|---------|------------|-------------------|-----|
| `drops` / `droppedFrames_` | pacer **Drop** only | play-path **`droppedFrames_.store(0)` :3009** | silence-scan ~:2312 |
| `publish_misses` / `publishMisses_` | DDR/FPGA publish fail | play-path **`publishMisses_.store(0)` :3010** | ring code ~:2432 |

Both already appear on every `media:` line via `frameLedgerTelemetryFragment`
(`drops_src=av_pacer`, `publish_misses_src=arm_publish_fail`).

## supply_ratio caveats (folded in)

- **Submitted vs played:** `audio_s` is MrAudio write bytes, not
  `audibleClockMs` (written − queued). Short intervals can overstate supply;
  min trustworthy single interval **d_wall ≥ 3 s** or N consecutive 1 s starved.
- **Per-stream only:** `audioBytes_.store(0)` at pump/play start (~:2298, ~:3119).

## Host red-before-green

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-avsync-lane
make "$PWD/build/test_supply_regime"
"$PWD/build/test_supply_regime"; echo "true rc=$?"
# expect: PASS RED path-starved rc=2 … PASS RED backpressure rc=3 … true rc=0
```

## Parent — after daemon deploy

```bash
# During starved 480p cast (bitrate > link or local brake):
grep -E 'supply_regime=|pipe_Bps=|pipe_fill_peak=|backpressure=|supply_ratio_class=' "$LOG" | tail -20
# Pre-reg:
# R1 path-starved session: supply_regime=starved_by_path backpressure=no pipe_fill_peak low
# R2 if Hold/DDR stalls dominate: supply_regime=starved_by_backpressure backpressure=yes
# R3 pipe_Bps_src=d_pipe_bytes/d_wall_s and pipe_bytes_scope=rawvideo_stdout_NOT_http always
# R4 never pipe_fill_peak=0.000 as a stand-in for failed FIONREAD (must be NO-DATA)
# R5 drops= and publish_misses= both present on same media: line
```

Coordinate: **w-cpu-1** owns Recv-Q / local-limiter RCA. This lane only makes
the regime visible in production telemetry.
