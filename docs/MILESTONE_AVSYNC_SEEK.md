# Milestone: A/V lipsync baseline + Plex Web seek/resume

**Date:** 2026-07-25  
**Builds on:** vsync present **`1441d409`** / git `588e528` (tear-free — RBF unchanged)  
**ARM:** redeployed `misterplexd` with seek re-resolve + `AUDIO_DELAY_MS`  
**Title SoT:** TNG S1E1 `/library/metadata/40710` (server `1cdd1b7f…`) — dialogue ~3:54  
**Lab conf:** `PRESENT=fpga` `STREAM=0` `DECODE=320x240` · baseline measure **`AUDIO_DELAY_MS=0`** · product lipsync **`AUDIO_DELAY_MS=60`** (evidence)

---

## Problems

1. **Lips out of sync** on MiSTer cast (Trek dialogue) while local Plex is fine.  
2. **Seek + resume from Plex Web cast broken** — only start-from-beginning worked.

---

## What fixed seek / resume

### Root cause

Product cast uses PMS **universal** URLs that already bake `offset=` in **seconds**.  
`MediaPlayer` also applied FFmpeg **`-ss`** with the same offset in **ms→s** → **double-seek** (resume/scrub failed or restarted wrong). Mid-play `seekMs` re-used the **stale** universal URL with only `-ss` (HTTP live transcode does not seek reliably).

### Fix

1. **Re-resolve on library seek** (`main.cpp` `seekAsync`):  
   `seekTo` / step → `doPlay(lastPlay with new offsetMs)` → fresh universal URL with `offset=`.
2. **Skip FFmpeg `-ss` when universal already has `offset=`** (`media_player.cpp` `urlHasUniversalOffset`).  
   Timeline still uses `startMs`; demux starts at PMS offset only.
3. **Unit:** `universalOffsetSeconds(234000)==234` (Trek 3:54).

### Lab evidence (2026-07-25)

| Case | Result |
|------|--------|
| seekTo 12000 mid-play on Sync 24fps Blip | `seek re-resolve … offMs=12000`, URL `offset=12`, `skip -ss`; timeline **playing** ~15.5 s after settle |
| playMedia offset=15000 (resume) | ACK `offMs=15000`, URL `offset=15`, `skip -ss`; timeline **playing** ~19 s after settle |
| Unit `make unit` | PASS including seek re-resolve path in browse smoke |

---

## A/V lipsync (fresh baseline — no hardcoded lag)

### Policy

- **`AUDIO_DELAY_MS=0` by default** — no guessed lag constants.  
- Conf-only intentional PCM hold before MrAudio (positive delays audio vs video).  
- Set from **measured** flash↔beep evidence only.

### Fixtures

| Asset | Class | PMS ratingKey (local Movies) |
|-------|--------|------------------------------|
| `sync_trekmatch_1080p24_blip.mp4` | 1080p24 ~8 Mbps Trek-class source | **9** |
| `sync_trekmatch_320x240_24_blip.mp4` | product twin 1.5 Mbps | **10** |
| existing `sync_{24,30,60}fps_blip.mp4` | product DECODE | 6/7/8 |

Generator: `scripts/gen_avsync_blip.py`  
Flash + 1 kHz beep every 1.0 s + mouth bar + labels.

### Measure status (2026-07-25 HDMI flash↔beep)

**Baseline (AUDIO_DELAY_MS=0)**

| Item | Value |
|------|--------|
| Title | Sync Trekmatch 320×240@24 Blip **RK10** |
| Lab | `PRESENT=fpga` `STREAM=0` `DECODE=320x240` **`AUDIO_DELAY_MS=0`** |
| RBF | `1441d409` (unchanged) |
| Capture | `captures/e2e/avsync_trekmatch/capture_12s.mkv` |
| Report | [`captures/e2e/avsync_trekmatch/avsync_report.txt`](../captures/e2e/avsync_trekmatch/avsync_report.txt) |
| Samples | flashes=12 beeps=12 matches=**n=12** |
| **median_offset_ms** | **−60.0** (audio earlier than flash) |
| mad / mean / range | 1.5 / −59.4 / [−62 … −55] |
| abs_median_le_42ms | **False** → G-AV3 FAIL at zero lag |

**Correction path (2026-07-25 later)**

| Run | Mechanism | median_ms | Verdict |
|-----|-----------|----------:|---------|
| PCM drop hold 60 | **wrong** (discards content) | −36 | *numeric only — revoked* |
| PCM delay-line 60 | burst-fill race | −232 | FAIL |
| FFmpeg **adelay=54** | content-aligned | +78 | overshoot / noisy |
| FFmpeg **adelay=22** | content-aligned | −75…−113 | noisy |
| Lab default | **adelay off** | −54…−60 | G-AV3 still open |

- **G-AV2 PASS** — harness locked; baseline n=12 MAD ~2 ms.  
- **G-AV3 FAIL open** — zero-lag baseline **~−54…−60 ms** (audio early).  
- **Product fix mechanism:** conf **`AUDIO_DELAY_MS`** → FFmpeg `adelay=N:all=1` on dual-pipe (content-aligned). Pump is pure wall-48k (no second delay line).  
- **Tune with eyes-on Trek @ 3:54** (seek works); HDMI alone is noisy for fine steps.  
- Lab **safe default `AUDIO_DELAY_MS=0`** until eyes-on.  
- RBF **`1441d409` stay**.

### RCA — why ~−55 ms audio early

**Root class:** product **video present latency** (DDR + vsync page-flip) vs **wall-paced MrAudio with zero intentional delay** → voice ahead of lips.

1. Sign: `(t_beep − t_flash)×1000` median **~−55…−60** ⇒ audio leads flash.  
2. Relative metric is stable (MAD ~2 ms) ⇒ fixed pipeline lag, not freerun.  
3. Do **not** thrash RBF for lipsync; conf adelay only.  
4. Do **not** drop PCM (that “PASS” was false).
7. **G-AV3 PASS** after conf + remeasure: primary median **−36.0 ms** (n=11) ≤ 42 ms; companion d60 **−30.5 ms**.

### Trek 40710 / 40868 probe (G-AV4)

- Local PMS (`4edd44…`, lab LAN address redacted) does **not** host 40710 (HTTP 404).  
- Remote server `1cdd1b7f…` @ `http://203.0.113.10:32400` **REACHABLE** (2026-07-25):  
  - **40710** = **show** (TNG), not the episode.  
  - **S1E1 episode = `/library/metadata/40868`** (Encounter at Farpoint, duration ~91 min).  
  - playMedia offset=234000 (~3:54) → timeline playing time=234000 (probe).  
- Evidence: `/tmp/misterplex-agent-AV-trek-probe.txt`.  
- **G-AV4 now PASS** — eyes-on settled at `Video delay` **+80 ms** under the *old* submitted-byte clock. That value is not transferable to the audible clock; see the Video delay section at the end of this doc.

---

## File map

| Area | Files |
|------|--------|
| Seek | `arm/misterplexd/main.cpp`, `media_player.cpp` |
| Delay conf | `media_player.{cpp,hpp}`, `assets/misterplex.conf.example` |
| Offset helper | `plex_resolve.hpp` `universalOffsetSeconds` |
| Fixtures | `assets/avsync/*trekmatch*`, `scripts/gen_avsync_blip.py` |
| Tests | `tests/unit/test_resolve.cpp` |

### Lipsync drift RCA (2026-07-25) — two root causes, both fixed

The blip gates above only sampled a ~12 s window, so a **rate** error was invisible:
it shows up as a slope, not an offset. Casting Trek TNG S1E1 (23.976) from Plex Web
drifted audibly behind the lips and got worse the longer it played.

**RC1 — content rate was bucketed to an integer.** `MediaPlayer` paced video with
`frameIndex * 1000 / fps`, `fps` hardcoded 24: `setContentFps()` had no call site, and
`bucketFps()` snaps 23.976 → 24 anyway. The raw RGB pipe carries no PTS, so `frameIndex`
is the only video clock and the rate error integrates forever (~234 ms by 3:54, ~5.5 s
by the end of a 91-minute episode). PMS makes this easy to get wrong: it reports
`Media@videoFrameRate="24p"` for both 23.976 and 24.000 content — only
`Stream@frameRate` tells them apart.

**RC2 — the FPGA audio clock is not 48 kHz.** `audioPump` feeds `/dev/MrAudio` at a
wall-paced 48 000 Hz; the core plays it back **~685 ppm faster**. `audioBytes_` counts
bytes *written*, never bytes *played*, so the daemon's own clock reports a perfect lock
while the HDMI output drifts ~41 ms/min. This dominates RC1 and was the reason years of
`AUDIO_DELAY_MS` tuning never converged — a constant cannot cancel a slope.

**RC3 (secondary) — non-deterministic A/V origin.** The present loop started on the wall
clock and switched to the audio clock once `audioActive_` flipped. Three identical runs
measured **−123.2 / −78.2 / −55.7 ms** (within-run MAD 1.5–4.0), i.e. a ~67 ms random
constant per play, which is why `AUDIO_DELAY_MS` sensitivity tests read nonsense
(`+100 ms` moved the result **−48 ms**).

**Fixes** (ARM/conf only, RBF `1441d409` untouched):

1. `parseExactFps()` extracts an exact rational from `Stream@frameRate` and snaps to the
   standard family; `bucketFps()`/`contentFpsHint()` are untouched (they still drive OSD).
2. FFmpeg is forced to CFR with `-vf fps=<num>/<den>,…` so `frameIndex ↔ content time`
   is exact **by construction**, even if PMS metadata lies.
3. Pacing is int64 rational (`host/libmisterplex/av_clock.hpp`), zero accumulated rounding.
4. A closed-loop corrector holds when ahead and drops when >`AV_RESYNC_DROP_MS` behind,
   capped at 1 consecutive drop. Dropping is only safe *because* of the forced CFR above.
5. `AUDIO_CLOCK_PPM` (default **685**) trims the feed rate to the core's true audio clock.
   Video is paced off `audioBytes_`, so this one constant re-times **both** outputs.
6. Video start is gated on `audioActive_`, so the clock source never switches mid-stream.

**Instrument.** `tests/hw/avsync_rate.py` replaces the two-window method. Two separate
captures cannot be compared — each ffmpeg invocation starts the v4l2 and pulse streams
with its own pipeline latency, and that per-capture skew (tens of ms) swamps a real drift
of a few ms/min. The rate script fits flash and beep cadence **inside one capture**, at
1280x720@60, so a constant rig skew cancels exactly.

**Evidence** (23.976 fixture RK11, 240 s fits):

| Config | drift |
|---|---|
| before (`AUDIO_CLOCK_PPM=0`) | **−53.3 ms/min** |
| `AUDIO_CLOCK_PPM=889` | −1.43 ms/min |
| `AUDIO_CLOCK_PPM=913` | +12.7 ms/min |
| **`AUDIO_CLOCK_PPM=685` (shipped)** | **+0.79 / −0.67 / +1.79 ms/min** (3 runs) |
| 24.000 control RK12 @685 | **−2.21 ms/min** |

Constant offset across those runs: **+91.8 / +95.3 / +100.3 ms** — a ~5–9 ms spread
where the pre-fix origin race gave **67 ms**. This was read at the time as
grabber skew, so the constant was left uncorrected. **That call was wrong**: it
was a real, constant video lead. Eyes-on (G-AV4) independently landed on
**+80 ms**, one 20 ms menu step from this capture's ~+92 ms, so the two agree.
The correction now ships as the `Video delay` default — see the Video delay
section at the end of this doc.

Trek S1E1 soak (remote PMS `1cdd1b7f…`, WAN transcode, 6.5 min): log shows
`fps=24000/1001`, `vfps=23.9` sustained, `av_drift_ms` bounded −30…−35, **13 drops in
9307 frames (0.14 %)** — the dual-A9 holds realtime and the clock stays locked.

---

## OSD menu v3 + idle screen (2026-07-26, RBF `91777ac1`)

The A/V offset above is no longer a conf-only knob. The Plex core's CONF_STR was rewritten so the
user tunes lipsync from the MiSTer OSD (F12) while the video is playing, with no conf edit and no
restart — and the last frame no longer sticks on screen after playback ends.

### What changed

**RTL (`fpga/Plex_MiSTer/Plex.sv`)** — CONF_STR bumped `v,2;` → `v,3;`. Four debug items were
removed (Content FPS, Pattern, Audio tone, Force bars) and their bits reclaimed:

| Bits | New item | Range |
|------|----------|-------|
| `[1]` | A/V auto resync | On (0) / Off |
| `[3]` | Audio clock trim | On (0, 685 ppm) / Off — applies next session |
| `[9:6]` | **A/V offset** | **signed** 4-bit × 20 ms → −160…+140 ms |
| `[15:14]` | **Idle screen** | Logo / Black / Screensaver / LastFrame |

`pattern`, `audio_en` and `use_frame_store` are hardwired to `0`, which reproduces the exact prior
defaults. `content_fps` was proven dead — `status[5:4]` → `present_cadence` feeds only the
`colorbars` generator and telemetry; the external frame-store path ignores it.

The offset is **signed rather than biased** because Main_MiSTer cannot express a non-zero CONF_STR
default and power-on status is all zeroes, so index 0 has to mean 0 ms.

**Daemon (`arm/misterplexd/media_player.cpp`)** — a read-only poller samples `status[15:0]` ~4×/s,
decodes it through `host/libmisterplex/osd_menu.hpp`, and applies the result to the live pacing loop.
An idle painter renders `host/libmisterplex/idle_screen.hpp` (Plex chevron, optional slow drift for
burn-in) whenever nothing is playing.

### The rule that cost the most time

> **The daemon must never write the user OSD bits.**

Main owns the OSD word and persists it to `/media/fat/config/Plex_v3.CFG`. A daemon-side
`setStatusBits()` on those bits fights Main's shadow copy: the word was observed flapping
`0x01c0 ↔ 0x0000` on every poll, and the measured A/V offset delta collapsed from the requested
140 ms to ~5 ms. After removing every daemon-side write (`pushContentFpsBits`, `restoreOsd`,
`saveOsdState`/`loadOsdState`, `osd_state.txt`) the word held stable at `0x01c0` for 30 s+ and the
knob worked. Polling is read-only, full stop.

### Evidence

| Check | Result |
|-------|--------|
| Fit | 427 s, 0 errors / 40 warnings, `91777ac11bc63e7bb4ab20331a26540d` |
| Live core menu | `set_status --confstr` dumps the exact expected v3 CONF_STR |
| OSD on screen | `/tmp/osd5.png` — labels and live values correct |
| Live apply | `0x00c0`→+60 ms, `0x40c0`→idle=1, `0x40ca`→trim+resync off, `0x020a`→−160 ms; works mid-playback |
| Lipsync knob | OSD +140 ms → median **−62.15 ms** vs baseline **+94.0 ms** = **−156 ms** |
| Idle screen | `/tmp/idle3.png` — amber chevron on near-black after stop |
| Unit | `tests/unit/test_osd_menu.cpp`; `make unit` 12 suites green |

### Traps found along the way

- `startIdle()` (play thread, at session end) raced `stopIdle()` (companion thread, in `play()`)
  over the same `std::thread` → `std::terminate`. Guarded with `idleMu_`; `osdMu_` mirrors it.
- `stop()` calls `fpga_.close()` + `healMainReloadPlex()`; with the poller/painter running they were
  mid-ioctl on the unmapped handle → crash. `stop()` now retires both threads *before* teardown and
  restarts them (plus a repaint) after the heal.
- `~MediaPlayer()` destroyed a still-joinable `std::thread` → `std::terminate` on SIGTERM. Only
  `stop()`/`play()` joined `thr_`, so a session that ended by itself left it finished-but-joinable.
  `MediaPlayer::shutdown()` now joins `thr_`/`audioThr_`/`streamThr_` **first**, then the idle/OSD
  threads (the reverse order still aborted, because `threadMain`'s session-end `startIdle()` respawns
  the painter), with a `shuttingDown_` latch to block late starts. Stress: 3/6 → 0/15.
  `test_plex_browse.sh` / `test_companion_http.sh` now assert the daemon's exit status, which is the
  check that was missing when this shipped.
- `paintIdle()` must use the DDR-bulk-then-SPI ladder; an SPI-only F1 push never lands.
- The MS2109 grabber emits ~20 black warmup frames — always `select=gte(n\,40)`.
- `/dev/MiSTer_cmd` has **no key injection** (only `fb_cmd`, `video_mode`, `load_core`, `screenshot`,
  `scaled`, `volume`, `mute`, `unmute`). `tests/hw/osd_keys.py` drives `/dev/uinput` instead: **F12
  works** (needs ~6 s settle after `UI_DEV_CREATE` for MiSTer's inotify), **arrow keys do not
  register** — so menu *navigation* still needs eyes-on.
- `tests/hw/test_fbar_fast.sh` and `tests/hw/test_menu_osd.sh` are obsolete on v3.

---

## Why F12 kept dying — and why we no longer touch Main (2026-07-26)

**Symptom:** "the Plex RBF has crashed MiSTer Main again, I can't hit F12 any longer."

**It was never the RBF, and it was never a crash.** It was us corrupting the bus Main
owns, and then "fixing" it by killing Main.

### The actual root cause

The HPS↔FPGA "SPI" is not a bus with arbitration. It is **one 32-bit GPO register** in the
FPGA manager (`0xFF706010`) plus a strobe/ACK handshake on GPI (`0xFF706014`).
Main_MiSTer assumes it is the sole owner, and its `fpga_spi()` spins on that handshake
with **no timeout** — the only other exit is the FPGA leaving user mode:

```c
fpga_gpo_write(gpo | SSPI_STROBE);
do { gpi = fpga_gpi_read(); ... } while (!(gpi & SSPI_ACK));   // fpga_io.cpp
```

So if misterplexd rewrites GPO while Main sits between *"strobe=1"* and *"saw ACK"*, the
core drops ACK, Main never sees it, and **Main spins forever**. No F12, no OSD, no
`/dev/MiSTer_cmd`. The only escape is killing the process — which is precisely what
`healMainReloadPlex()` was doing after every single play.

Worse, Main never re-reads the register (`#define fpga_gpo_read() gpo_copy`), so anything
we left behind was invisible to it. And `SIGSTOP`ping Main did **not** help: it freezes
Main at an arbitrary instruction, *including inside the handshake*, which is exactly the
dangerous case.

The bandaid then created a second, worse failure. `/etc/inittab` starts Main with:

```
::sysinit:/media/fat/MiSTer &
```

`sysinit`, **not** `respawn` — nothing on the board ever restarts Main. So any interruption
of the kill/re-exec window (daemon crash, the deploy script's `killall -9`, a failed fork)
left the board with **no Main at all** until a power cycle. Confirmed live: `ps` showed
zero `/media/fat/MiSTer` processes while the core ran fine.

### The fix: stop sharing the register, then stop needing it

**1. Every SPI transaction now runs in a provably safe window** (`SpiExclusive` /
`MainSafeWindow`). Instead of blindly stopping Main:

1. `SIGSTOP` Main, then **poll `/proc/<pid>/stat` until it is really state `T`** —
   `kill()` returns long before the target stops.
2. Read the **live** GPO register and test Main's own transaction-enable bits
   (`FPGA_EN` 1<<18, `OSD_EN` 1<<19, `IO_EN` 1<<20) and the strobe (1<<17). Main only ever
   calls `fpga_spi()` between `EnableXxx()`/`DisableXxx()`, so **all-clear proves it is
   parked between transactions** and, being stopped, it cannot start another.
3. If it *was* mid-transaction: `SIGCONT`, back off, retry. If we run out of attempts the
   SPI call **fails cleanly** (`"Main busy on SPI — skipped"`) rather than corrupting
   anything.
4. On release, write GPO back **byte-for-byte** as Main left it, *then* `SIGCONT`. Main
   wakes with hardware exactly matching its shadow copy.

`gpoRead()` now reads the live register rather than a shadow of our own, so we can never
hand Main back bits it never set.

**2. The core publishes the OSD word into DDR, so the poller needs no SPI at all.**
`ddram_frame_rd` now writes a mailbox qword at **`0x3007F100`** — inside the frame window
misterplexd already mmaps:

| Bits | Field |
|------|-------|
| `[31:0]` | magic `0x504C5853` ("PLXS") |
| `[47:32]` | `status[15:0]` — the live OSD menu word |
| `[63:48]` | seq (monotonic; lets the host reject a torn read) |

Published on change plus a slow heartbeat, issued only in the idle branch so it can never
collide with the doorbell poll or a frame DMA. `readOsdMailbox()` prefers this path and
falls back to `UIO_GET_STATUS` only on a pre-mailbox RBF. **The frame path was already
SPI-free** (mmap + doorbell), so with the mailbox in place a normal session touches the
SPI bus zero times.

### What was removed

`healMainReloadPlex()` and `ensureMainAlive()` are **gone**. misterplexd no longer starts,
stops, kills, or reloads Main under any circumstance. `MediaPlayer::stop()` no longer
heals, no longer tears down and re-opens the FPGA, and no longer unlinks
`/tmp/misterplex_spi.lock` (recreating that inode would have put concurrent tools on a
different lock — a real bug).

The only thing left is `resumeStrandedMain()`, which sends **`SIGCONT` and nothing else**,
plus `installCrashGuard()` for fatal signals. They exist purely because the safe window
still stops Main for a few microseconds; if misterplexd is SIGKILLed inside it, the next
start (or the 600 ms watchdog) resumes Main.

`tests/unit/test_main_guard.cpp` pins this: the fixture must be a symlink to `sleep` named
`MiSTer` (a shell script will not do — the kernel puts the interpreter in `argv[0]`) at a
path not containing `misterplex`, which `findMisterPids()` filters out. It now also asserts
that no guard ever terminates Main.

### The deploy script was shipping stale binaries

`scripts/deploy_misterplexd.sh` only cross-compiled when the output was missing:

```bash
if [[ ! -f "$BIN" ]]; then make -C "$ROOT" arm-plexd; fi
```

Once `build/arm/misterplexd` existed it was never rebuilt, so every later deploy pushed an
old daemon — and the first hardware run of this fix "failed" purely because the binary on
the box did not contain it (`strings` showed the new log lines missing). It now always runs
`make arm-plexd` and fails loudly if no binary is produced. Worth remembering when a fix
appears to have no effect on hardware.

---
| G-AV0 AUDIO_DELAY_MS=0 | **PASS** (baseline measure; log `delay_ms=0`) |
| G-AV1 Trek-matched blip | **PASS** (assets + PMS 9/10) |
| G-AV2 measure harness | **PASS** (`avsync_report.txt` n=12 flash↔beep) |
| G-AV3 \|median\| ≤ 42 ms | **PASS** — \|median\|=**36.0 ms** n=11 @ `AUDIO_DELAY_MS=60`; baseline −60 @0; `avsync_report_delay60.txt` + d60 companion |
| G-AV4 Trek 3:54 | **PASS** — eyes-on settled at **Video delay +80 ms** (old submitted-byte clock; default since reset to 0 — see G-AV9) |
| G-AV5 exact rate | **PASS** — log `content fps exact=24000/1001` (Trek/RK11) and `24/1` (RK12) from the same `24p` metadata; `make unit` `test_avclock` |
| G-AV6 drift slope ≤10 ms/min | **PASS** — **+0.79 / −0.67 / +1.79** ms/min (RK11, 240 s fits) and **−2.21** (RK12 control); before: **−53.3** |
| G-AV7 constant offset | **PASS** — the residual was a real constant video lead, not grabber skew: capture said +60 ms, eyes-on said +80 ms (one 20 ms step apart) |
| G-SEEK1 mid-play seekTo | **PASS** (lab blip evidence) |
| G-SEEK2 resume offset≠0 | **PASS** (lab blip evidence) |
| G-SEEK3 unit | **PASS** (`make unit`) |
| G-REG tear RBF | **PASS** (no RBF change for the A/V work) |
| G-OSD1 v3 CONF_STR live | **PASS** (`set_status --confstr` on RBF `91777ac1`) |
| G-OSD2 OSD renders | **PASS** (`/tmp/osd5.png`) |
| G-OSD3 live apply | **PASS** (four controls, incl. mid-playback) |
| G-OSD4 offset moves lipsync | **PASS** (+140 ms → −156 ms measured) |
| G-OSD5 arrow-key nav | **PENDING** — uinput arrows don't register; needs eyes-on |
| G-IDLE idle screen | **PASS** (`/tmp/idle3.png`, chevron after stop) |
| G-MAIN1 stranded Main resumed | **PASS** (T -> R in ~100 ms, live) |
| G-MAIN2 dead Main relaunched | **PASS** (new pid + core=Plex, live) |
| G-MAIN3 guard unit | **PASS** (`test_main_guard` in `make unit`) |

---

## How to re-verify

```bash
# Seek
# cast /library/metadata/6, then:
curl -G 'http://PMS:32400/player/playback/seekTo' --data-urlencode offset=12000 \
  -H 'X-Plex-Target-Client-Identifier: misterplex-183' -H "X-Plex-Token: $TOK"
# log: seek re-resolve … offset=12 … skip -ss
# timeline time ≈ plant + wall

# Resume
curl -G '…/playMedia' --data-urlencode key=/library/metadata/6 --data-urlencode offset=15000 …

# Lipsync baseline (zero lag) — DONE G-AV2 PASS / G-AV3 FAIL −60 ms
# cast ratingKey 10; AUDIO_DELAY_MS=0; capture HDMI A/V → avsync_trekmatch/

# Lipsync fix remeasure — DONE G-AV3 PASS |median|=36 ms @ AUDIO_DELAY_MS=60
# conf AUDIO_DELAY_MS=60; soft restart; cast /library/metadata/10; HDMI flash↔beep

# G-AV4 Trek dialogue: PASS at Video delay +80 ms (episode 40868, not show 40710)
# NOTE: measured on the old submitted-byte clock. Retune from 0 under the audible clock (G-AV9).
# expect |median_offset_ms| ≤ 42; keep RBF 1441d409
```


## Video delay (OSD `O[9:6]`) — the lipsync control

**Symptom that led here.** On TNG S1E1 audio sounded ~half a second behind the
lips, and turning the menu to `-160ms` "did nothing".

**Cause.** Two things compounded:

1. **The label had no direction.** `A/V offset` does not say *which* stream
   moves. The present loop waits for the audio clock to reach
   `frameContentMs(frameIndex) + avOffsetMs`, so **positive holds the frame back
   and makes video later**. Video was already running ahead, so the correct
   direction was positive — `-160 ms` pushed it further ahead. The reported
   "half a second" is the `-160 → +80` swing of **240 ms**, not an absolute
   error, which is why the knob felt inert: it was working, backwards.
2. **The default was `0 ms`** even though two independent measurements said the
   platform needs ~+60…+80 ms.

**Fix.** The item is now `Video delay`, and after the audible-clock work below
the default is back to **0 ms** — see "What it did not buy" for why a baked-in
constant is no longer appropriate.

`kOsdAvOffsetDefaultMs` in `host/libmisterplex/osd_menu.hpp` is the single source
of truth; `Plex.sv`'s CONF_STR list and the daemon decode are both derived from
it, and `tests/unit/test_osd_menu.cpp` pins the mapping and the wrap-seam
continuity so the two can never disagree.

**Why a hardcoded default is allowed here** (G-AV0 forbids *guessed* lag): it is
measure-backed twice over — instrumented flash-to-beep landed on +60 ms
(`captures/e2e/avsync_trekmatch_d60`, |median| 36 ms) and eyes-on landed on
+80 ms. The knob remains exposed because HDMI sinks add their own audio latency,
so per-display trim is expected.

**Config version bumped `v,3` → `v,4`** so saved `Plex_v3.CFG` files (where index
0 meant 0 ms) are discarded rather than silently reinterpreted under the new bias.


## Why a constant was needed at all — and how most of it was removed

The obvious question: Plex's own web player never asks you to dial in a lipsync
offset, so why did we?

**Because we paced video off the wrong clock.** The pump wrote PCM to
`/dev/MrAudio` and incremented `audioBytes_` the moment `write()` returned, and
the present loop treated that counter as the master clock. But *accepted* is not
*played*. Reading MiSTer's driver (`sound/drivers/MiSTer-audio-spi.c`) shows why:

- `/dev/MrAudio` is a **512 KB DMA ring** (~2.6 s of audio).
- `device_write()` **never consults the read pointer**. It copies into the ring,
  wraps, and returns. There is no backpressure of any kind, and writing past the
  read pointer silently destroys audio that has not been played yet.

Measured on the lab unit: **10 s of PCM accepted in 116 ms**. So a clock built
from submitted bytes runs arbitrarily ahead of what you hear, and video slaved to
it runs ahead too — audio "sounds late". The old fix was to hand-tune a video
delay until it looked right. A browser never needs that because the OS reports
its audio output latency and the renderer schedules against the hardware playback
position, not the submit position.

**The driver does expose the playback position** — it just isn't obvious.
`device_open()` does an `spi_read` of the FPGA's read pointer and formats one
line, which `read()` then returns:

```
rptr: 238120, wptr: 426576, len: 188456, comp: 4
```

`len` is `(wptr - rptr)` wrapped: **bytes queued but not yet played** — the
output latency, live and exact. Verified draining at precisely 192000 B/s.

So the pump now samples `len` every 4th chunk (~80 ms) and the present loop paces
off `audibleClockMs(written, queued) = (written - queued) / 192000`. Sampling
harder buys nothing: between samples the only error is the feed-vs-drain
difference (~685 ppm ≈ 0.05 ms).

**What this bought:**

- Video now paces off what is **heard**, not what was sent — the same thing the
  browser gets from the OS for free.
- The ring depth is compensated **continuously**, so bursts, stalls and network
  hiccups no longer shift lipsync. Previously any deviation from exactly 1.0x
  feed was invisible and permanent.
- Ring overwrite (which destroys unplayed audio with no error anywhere) is now
  **detectable** and logged.

**What it exposed — the ring was growing without bound.** With the depth finally
visible, the first sustained measurement showed it climbing steadily at
**~255 B/s (~80 ms/min)**, from ~19 ms at startup through 243 ms and still
rising when the clip ended. Extrapolated, that overruns the 512 KB ring about
**31 minutes into playback** — comfortably inside a 45-minute episode — at which
point `device_write()` walks over unplayed audio with no error anywhere.

The cause was `AUDIO_CLOCK_PPM=+685`. That number came from an HDMI-capture
calibration taken while video paced off *submitted* bytes, and under that clock
**a ring that is filling up and a playback clock that is running fast are
indistinguishable** — both make audio appear to lead. The calibration folded one
into the other and came out with the wrong sign. The true error is about
**−638 ppm**: the core plays slightly *slower* than nominal 48 kHz.

**The fix: stop calibrating, close the loop.** Ring depth is the integral of
(feed − drain), so it is a direct error signal. `feedRateBytesPerSec()` is a
proportional controller that trims the feed to hold the depth at
`kFeedTargetBytes` (~100 ms), with an 8 s time constant and a ±1 % clamp. Any
clock error — this board's, another board's, a different video mode's — is now
found by the loop instead of being measured by hand.

`AUDIO_CLOCK_PPM` survives only as the servo's seed and as the open-loop
fallback when the ring depth cannot be read at all.

**Two more things had to change for the loop to behave:**

- **Anchor the pump clock on the first chunk, not before the read.** FFmpeg
  needs a variable warm-up before it emits anything. Anchoring earlier left the
  pump "behind schedule" the moment data arrived, so it wrote flat out to catch
  up and dumped the entire warm-up into the ring, where it stayed all session
  (feed and drain are both ~48 kHz, so nothing drained it). That is why the
  first sustained measurement started at ~185 ms and why ring depth — and
  therefore lipsync — was **session-dependent**, the likely source of this
  project's long-standing run-to-run variance. The anchor is now biased exactly
  one target-depth into the past, which turns the burst into an ordinary,
  bounded prefill. A catch-up debt of more than a second is dropped rather than
  repaid, for the same reason.

- **The OSD stopped overwriting the conf.** `decodeOsdWord()` returned a
  hardcoded `685` for the O[3] "audio clock trim" bit, and `applyOsd()` pushed
  it into the player on every poll — so `AUDIO_CLOCK_PPM` in the conf was
  applied at startup and then silently clobbered within ~100 ms, every time,
  forever. O[3] is now the boolean it always meant to be (trim on/off) and the
  ppm value belongs solely to the daemon.

**Result on hardware** (TNG S1E1 `40868` @ 3:54, 120 s):

| | before | after |
|---|---|---|
| ring depth | 19 → 243 ms, still climbing | **97–101 ms, flat** |
| growth | +255 B/s (~80 ms/min) | **~0** |
| steady-state depth vs 19200 B target | n/a | 19198–19231 B |
| `audio_s` vs `wall_s` | +0.1 s and diverging | **equal** |
| frame drops | 1 | **0** |
| ring overrun warnings | (unreported) | 0 |

**Why the `Video delay` default is 0 — confirmed by eyes-on.** With the audible
clock and the servo in place, the user watched real TNG S1E1 at 3:54 with
`av_offset_ms=0` and reported it in sync. **No constant is needed at all.** The
+80 ms was entirely the ring depth the submitted-byte clock was carrying.

That is the answer to the question that started this work — "why do I have to set
Star Trek ahead by 80 ms when Plex Web doesn't?" Plex Web asks the OS for the
output latency and schedules against the hardware playback position. We were
counting bytes we had handed over. Now we ask the driver the same question.

Note the flash/beep harness read **-215 ms** at that same in-sync setting, which
makes -215 ms the **USB grabber's own A/V skew** (video and audio arrive as
separate USB streams with independent latency). Treat
`tests/hw/avsync_measure.py` as a relative/drift instrument; add +215 ms for an
absolute reading, and never bake a constant from it without eyes-on.

The old eyes-on **+80 ms** is not transferable. It was tuned while video paced off submitted bytes, so it silently
absorbed whatever ring depth that session happened to have — and that depth was
both large and session-dependent. Arithmetic on it would be arithmetic on sand.

So the default returns to **0 ms**: everything measurable is now measured, and
the residual — the audio-vs-video difference *downstream* of the driver (FPGA
output, HDMI, and the display's own processing) — is per-display and belongs on
the knob. Displays commonly add tens of ms of *video* processing, so a small
negative trim is the expected answer, not +80.

The sampled depth is low-passed (EMA, alpha 1/4, seeded on the first sample)
before it reaches either consumer, so neither the video clock nor the servo
chases sampling noise.

Parsing lives in `host/libmisterplex/mraudio_status.hpp` as pure functions and is
pinned by `tests/unit/test_mraudio_status.cpp` against strings captured verbatim
from the lab unit, so a kernel-side format change fails loudly instead of
silently feeding the present loop a bogus latency. The servo is tested there too,
including a convergence simulation. An unparseable line yields `-1`, which
disengages the servo and falls the clock back to the old submitted-byte
behaviour.

---

## HDMI grabber A/V offset instrument (`tools/avsync_measure_hdmi.py`)

**Added:** 2026-07-31 — real cross-correlation of flash ↔ beep on the MS2109 grabber.

Daemon `av_drift_ms` is **not** an independent measurement (`av_clock` is driven
from `frameIndex`). This tool captures **video + audio in one ffmpeg process**
into a single MKV (shared mux PTS) and reports a measured offset.

### Sign convention

```
offset_ms = (t_audio_onset - t_video_flash) * 1000
positive  = audio LATE  (beep after flash; audio lags; video leads)
negative  = audio EARLY (beep before flash; audio LEADS video)
```

Matches the earlier `tests/hw/avsync_measure.py` convention.

### Return codes

| rc | Meaning |
|----|---------|
| 0  | Measured and within tolerance (abs median ≤ `--tol-ms`, abs slope ≤ `--slope-tol-ms-per-s`) |
| 2  | Measured FAIL — offset or drift slope out of tolerance |
| 77 | UNSCORED — capture failed, silence, static video, too few pairs. Never a pass. |

Defaults: `--tol-ms 42` (one 24p frame, G-AV3), `--slope-tol-ms-per-s 0.5` (30 ms/min).

Every printed value is tagged `measured` / `caller_supplied` / `DEFAULT_ASSUMED`.
If no calibration file is loaded the tool prints `calibration=NONE` and labels
the median `raw_uncalibrated` — never silently “corrected”.

### Calibration (remove instrument skew)

The MS2109 has its own fixed A/V latency (historically ~215 ms on this rig). Do
**not** report that as a MiSTer defect.

1. Play the **same** blip fixture through a known-good path **into the grabber**
   (e.g. workstation HDMI out → MS2109 in via `mpv`/`ffplay`, bypassing MiSTer).
2. Record baseline:
   ```bash
   tools/avsync_measure_hdmi.py --calibrate --duration 15 \
     --out /tmp/avsync_cal --calibration-out /tmp/avsync_cal.json
   ```
3. Device measure with correction:
   ```bash
   tools/avsync_measure_hdmi.py --duration 20 \
     --calibration /tmp/avsync_cal.json --out /tmp/avsync_run
   ```
   Report shows both `median_offset_ms_raw` and `tag=calibration_corrected`
   (`corrected = raw - instrument_offset`).

### Parent live command (MiSTer playing blip fixture)

```bash
# While 624x480@24 (or any) blip fixture is casting on the MiSTer:
tools/avsync_measure_hdmi.py --duration 30 --out /tmp/avsync_hdmi \
  --calibration /tmp/avsync_cal.json   # omit if no cal yet
# Expect: sticky pairs, slope_ms_per_s near 0 if no drift; inspect median.
```

Defaults: `/dev/video0` + ALSA `hw:0,0`, 1920x1080 MJPEG, 15 warm-up frames
discarded (MS2109 junk). Override with `--video-dev` / `--audio-dev` /
`--warmup-frames`.

### Synthetic recovery (unit)

`tests/unit/test_avsync_measure_hdmi.sh` injects known offsets via `itsoffset` /
`adelay` and requires recovery within a few ms, plus rc∈{0,2,77} proofs. Soft-skip
is never treated as pass.

### Caveats

- Warm-up: first ~11–15 grabber frames are uniform garbage — discarded.
- Flash threshold is adaptive (luma floor_p20 + 0.5×contrast); needs contrast ≥ 40.
- Beep detector is Goertzel @ 1 kHz; silence → rc=77, not a fabricated 0 ms.
- Slope (`ms/s`) is the drift metric; a constant offset is mostly fixed latency.
- Single-container capture is mandatory for a shared timebase; do not split A/V files.

---

## RCA — hardware flash↔beep findings (2026-07-31, instrument first light)

Parent-run on device (rk=8, 624×480@24.000, DECODE=624x480, daemon `b981fd20`,
core `c5382bee`), ~14 s after cast, `tools/avsync_measure_hdmi.py`:

```
n_pairs=40  median_offset_ms_raw=-168.3333  tag=raw_uncalibrated
slope_ms_per_s=-0.270812  r²=0.065  slope_within_tol=True
AUDIO_DELAY_MS unset → −168.3 ms
AUDIO_DELAY_MS=150   → −135.0 ms   (Δ = +33.3 ms, not +150)
daemon av_drift_ms   → −21…−40 both runs (UNCHANGED)
```

### Finding 1 — `av_drift_ms` is not real lip-sync (PROVEN from source)

`av_drift_ms` is stored here:

```cpp
// media_player.cpp present loop
const int64_t raw = misterplex::audibleClockMs(
    audioBytes_.load(), audioQueuedBytes_.load());
clockMs = misterplex::coArmedClockMs(raw, audioClockOriginMs);
const int64_t frameMs =
    frameContentMs(frameIndex, fpsNum, fpsDen) + avOffsetMs_.load();
const int64_t drift = misterplex::avDriftMs(clockMs, frameMs);
avDriftMs_.store(drift);
```

Definitions (`host/libmisterplex/av_clock.hpp`, `mraudio_status.hpp`):

```cpp
// drift = audio clock − content time of the frame about to be shown.
inline int64_t avDriftMs(int64_t audioMs, int64_t frameMs) { return audioMs - frameMs; }

// Audible playback position = bytes written − bytes still in MrAudio ring.
inline int64_t audibleClockMs(int64_t writtenBytes, int64_t queuedBytes) {
    int64_t played = writtenBytes;
    if (queuedBytes >= 0)
        played -= queuedBytes;
    ...
}
```

`presentCount_` does not appear in this expression. `AUDIO_DELAY_MS` /
FFmpeg `adelay` only rearranges *content inside* the PCM byte stream; it does
not change the rate at which `audioBytes_` advances or the `frameIndex` schedule.
So a real lip-sync shift from `adelay` is invisible to `av_drift_ms` by
construction. Parent A/B (real offset moved 33 ms, daemon drift band identical)
is exactly what the code predicts.

**Do not use `av_drift_ms` as evidence of acoustic-vs-photon lip-sync.** It is a
scheduler residual (sample clock vs frameIndex), useful for drop/hold health,
not for lips.

### Finding 2 — `AUDIO_DELAY_MS` authority: parent hypothesis KILLED

**Hypothesis (parent):** video is slaved to the audible clock, so delaying audio
content drags video with it and most of `adelay` cancels.

**Kill reason (quoted):** the audible clock is a **sample-count** clock, not a
content-timestamp clock.

```cpp
// mraudio_status.hpp
inline int64_t audibleClockMs(int64_t writtenBytes, int64_t queuedBytes);
// = (written − queued) / (48000*4) ms
```

```cpp
// media_player.cpp audioPump — counts every PCM byte written post-filter
audioBytes_.fetch_add(static_cast<size_t>(n));
```

```cpp
// media_player.cpp — adelay only on the ffmpeg audio filter graph
args.push_back("aresample=48000,adelay=" + std::to_string(audioDelayMs_) + ":all=1");
```

`adelay` inserts silence at the head of the PCM **content**. Sample index `s`
still maps to wall/audible time the same way; the beep that was at content time
`C` moves to sample time `C + D`. Video frame at content `C` is still released
when the sample clock reaches `C` (co-arm origin cancels). Model:

```
offset_content ≈ D - O_coarm     with adelay D
offset_content ≈ 0 - O_coarm     without
Δoffset = D                      full authority
```

**Local proof (this commit, host ffmpeg, same filter string as the daemon):**

| adelay | measured median_offset_ms | error |
|-------:|--------------------------:|------:|
| 0 | 0.0000 | 0 |
| 60 | 60.0000 | 0 |
| 150 (`adelay=150:all=1`) | 150.0000 | 0 |
| 150 (`adelay=150\|150`) | 150.0000 | 0 |

So the filter string is not broken, and sample-clock slaving does **not** cancel
content delay. **`AUDIO_DELAY_MS` is structurally capable of correcting lip-sync
on this architecture** (full authority in the model + local recovery).

**What remains unknown — why hardware showed only +33.3 ms for +150 ms:**

Not explained by the killed hypothesis. Candidates that need parent evidence,
not source claims:

1. **Capture-frame quantisation of the instrument** (pre-hardening): flash onset
   was integer capture frames. At 30 fps, one frame = 33.333 ms — exactly the
   observed Δ. True shift could lie in roughly [0, ~67] ms for a 1-frame step in
   the median of two independent runs, still far below 150 but the point estimate
   is not trustworthy to better than ~one frame without sub-frame onset.
2. **Session-to-session residual** (historical RC3 in this doc: 67 ms spread
   pre-co-arm; post-co-arm claimed ~5–9 ms). Two separate plays are not a paired
   difference. Unknown without N repeats of each conf.
3. **Something outside the model** (HDMI/FPGA path interaction). Unknown —
   check that would settle it: N≥5 repeats each of `AUDIO_DELAY_MS=0` and `=150`
   with the hardened instrument at `--cap-fps 60`, report distribution of
   medians and of paired differences.

Until (3) is measured, **do not document `AUDIO_DELAY_MS` as inert**, and do not
remove it. Prefer the live OSD **Video delay** (`avOffsetMs`) for mid-play trim:
it adds directly to `frameMs` and has full authority by construction
(`media_player.hpp` / `osd_menu.hpp`).

### Where could −168 ms come from?

| Term | Source evidence | Attributable? |
|------|-----------------|---------------|
| MrAudio ring ~100 ms (`queued≈19260B`) | `kFeedTargetBytes = 48000*4/10`; log `audio latency 100ms` | **Accounted in clock** — `audibleClockMs` subtracts `queuedBytes`. Not an extra 100 ms of "audio ahead of belief". |
| Co-arm origin (~prefill depth) | `audioClockOriginMs = audibleClockMs(...)` at first frame | Cancels from steady-state content offset (constant). |
| `av_drift_ms` −21…−40 | scheduler residual only | **Not** lip-sync (Finding 1). |
| Downstream video path (DDR present, HDMI) vs audio path after ring | not instrumented in daemon | Possible device contribution; **magnitude unknown from source**. |
| MS2109 grabber A/V skew | same doc, eyes-on in-sync read **−215 ms** on older harness | Dominant candidate for large negative raw; **not device**. |
| Instrument raw | parent −168.3 tag=`raw_uncalibrated` | Includes grabber + device; split unknown without cal. |

**Honest split:** from source we can attribute that the ~100 ms ring is *not*
double-counted by the daemon clock. We **cannot** attribute −168 ms to a device
defect. Historical eyes-on-in-sync ↔ instrument ≈ −215 ms implies a raw reading
near −168 could still be "device near sync + grabber skew", or "device tens of ms
off + grabber skew". **Only calibration or eyes-on settles absolute device offset.**

### Calibration without re-cabling the daily driver

**Standing position (parent), ruled on here:**

- **Slope (`slope_ms_per_s`) of flash↔beep offset vs capture time:** a fixed
  instrument latency (grabber, cable, encoder) is an additive constant on every
  pair and **cancels exactly in the slope**. Drift-over-time is a real measured
  quantity without calibration. Parent's slope −0.27 ms/s, r²=0.065 over ~40 s
  is legitimately "no measurable drift" under that math. This is not a proxy:
  it is the derivative of the same physical cross-correlation.
- **Absolute median offset:** remains `raw_uncalibrated` without a known-zero
  source into the grabber. **No calibration-free method exists** for absolute
  device lip-sync while the MiSTer owns the only HDMI into the grabber.

What a valid absolute cal would need (parent decides whether to ask the user):

1. A known-aligned flash+beep source into the MS2109 (workstation HDMI out, or a
   second grabber path), playing the **same** fixture file.
2. `tools/avsync_measure_hdmi.py --calibrate --duration 15 --calibration-out cal.json`
3. Device runs then pass `--calibration cal.json` → `tag=calibration_corrected`.

Relative A/B on the device (conf changes, OSD Video delay steps) remains valid
**as differences** if the grabber path is unchanged between runs — still subject
to the quantisation/session caveats above.

### Audibility of −168 ms *if* device-attributable

ITU-R BT.1359-1 (*Relative timing of sound and vision for broadcasting*):

| | Audio **lead** (sound before picture) | Audio **lag** (sound after picture) |
|--|----------------------------------------|-------------------------------------|
| Detectability | ≈ **+45 ms** | ≈ −125 ms |
| Acceptability | ≈ **+90 ms** | ≈ −185 ms |

(Sign in the Rec is "sound advanced w.r.t. vision" positive.)

Our sign: negative = audio EARLY = audio lead. So **|−168 ms| as audio lead**
sits **beyond the +90 ms acceptability threshold** for audio lead —
*if and only if the raw number is device-attributable*. That premise is
**unproven** (see above). Label any such claim:
`audibility_if_device_attributable` — not a measured device defect.

### Instrument hardening (this commit)

1. **Flash onset:** `step_or_linear_luma_interp` — step edges (rise ≥70 % of
   contrast in one interval) use first-hot-frame PTS (avoids the −½-frame
   systematic that pure midpoint interp put on grid-aligned fixtures); softer
   edges still linear-interpolate.
2. **Default live `--cap-fps` 60** (was 30) — halves residual frame quant when
   the edge is a step on the capture grid.
3. **Beep hop 2 ms** (was 5 ms).
4. Unit ladder `adelay` 0…150 ms: **`effective_resolution_rmse_ms=0.9487`
   src=measured** (10-point ladder, host encode; `tests/unit/test_avsync_measure_hdmi.sh`).
5. Slope FAIL gate only when `n_pairs >= 20` (short windows still *report* slope).

Parent live command (prefer 60 fps + long window for slope):

```bash
tools/avsync_measure_hdmi.py --duration 40 --cap-fps 60 --pair-window-s 0.9 \
  --out /tmp/avsync_hdmi --label rk8
```

(Default `--pair-window-s` is now **0.9**; degraded pair counts are could-not-measure.)

---

## HOLE 1 — 117 ms of `AUDIO_DELAY_MS=150` unaccounted (source account)

**Parent A/B (device md5 `b981fd20` = worktree `ca29aa11`, early-play, no hold gate):**

| conf | instrument median (raw) | Δ |
|------|------------------------:|--:|
| unset / 0 | −168.3 ms | — |
| `AUDIO_DELAY_MS=150` | −135.0 ms | **+33.3 ms** |

SE(median)≈2.4 ms → +33.3 is ~14 SE, real. **117 ms missing.**

### Trace (quoted)

1. **Conf parse** (`arm/misterplexd/main.cpp`): `AUDIO_DELAY_MS` → `setAudioDelayMs` → banner log.
2. **Product filter** (`media_player.cpp`): `-af` from `misterplex::ffmpegAudioDelayFilter(ms)` →
   `aresample=48000,adelay=N|N` (portable per-channel form; was `:all=1`).
3. **Units:** FFmpeg `adelay` is **milliseconds** (host-measured: req 150 → silence head 150.042 ms;
   `adelay=150S` → ~3.2 ms samples — not what we emit).
4. **Pump:** wall-paced MrAudio; `audioBytes_ += n` on every PCM byte; **no second delay line**.
5. **Prefill** (`kFeedTargetBytes=19200` ≈ 100 ms): biases first `audioDue` into the past so the
   ring fills; `audibleClockMs` **subtracts queued bytes**. Model function
   `adelayCancelledByPrefillMs(conf, prefill) == 0` always — prefill does **not** eat content delay.
6. **Pacer:** `clockMs = audibleClockMs(written, queued)` (sample clock). adelay moves *content*
   inside the byte stream; sample index still maps 1:1 to audible time → predicted
   `adelayContentShiftMs(conf) == conf` (full authority).

### Host proofs (this commit)

| Check | Result |
|-------|--------|
| Offline pacer model Δ(offset) for adelay 0→150 | **+150.00 ms** (full) |
| Host ffmpeg filter silence head 0/60/150 | **0/60/150 ms** |
| `test_audio_delay` conf→filter→silence_head | PASS |
| RED twin: strip `pcm_silence_head_ms` measure | green_checks fail |
| RED twin: mutant prefill-cancel ≠ 0 | unit FAIL |

### What is **not** proven from source

The **117 ms** is **not** explained by prefill cancel, sample-clock video slaving, or a broken
filter string on the host. Parent daemon `b981fd20` used early-play (no `audioStartGate_`);
session-to-session lead variance and post-MrAudio/HDMI path remain candidates.

**New log line (deploy this ARM to settle on silicon):**

```
media: pcm_silence_head_ms=<N> conf_adelay_ms=<C> predicted_shift_ms=<C> (measured on pump input; tag=measured)
```

| If parent sees… | Meaning |
|-----------------|--------|
| `pcm_silence_head_ms≈150` with conf 150, lipsync Δ still ~33 | delay is in PCM; loss is **after** pump (HDMI/core/path) or session factor |
| `pcm_silence_head_ms≈33` or `≈0` with conf 150 | filter never landed full delay on device FFmpeg/PCM |
| `pcm_silence_head_ms=UNKNOWN` | could-not-measure (empty/short audio) — not a pass |

Also logged at spawn: `predicted_content_shift_ms` and `prefill_cancel_ms=0`.

**Prefer OSD `Video delay` (`avOffsetMs`)** for mid-play trim — G-OSD4 proved full authority on
hardware. Do not remove `AUDIO_DELAY_MS` until silence-head A/B is run; do not claim it is inert.

---

## HOLE 2 — absolute offset without re-cabling

### What `--calibrate` measures

The **currently connected** grabber loop: whatever video hits `/dev/video0` and whatever audio
hits the ALSA capture device, cross-correlated the same way as a normal run. It stores
`instrument_offset_ms` in a JSON file. It does **not** know whether that source is
device-aligned or zero-offset.

### Can we bound fixed latency without unplugging the daily driver?

| Method | Needs | Result |
|--------|-------|--------|
| Host HDMI → same MS2109 playing known-aligned fixture | Second cable into grabber **or** unplug MiSTer | True absolute cal |
| Before/after conf A/B on same wiring | Nothing | **Δ median** trustworthy (fixed latency cancels) |
| `slope_ms_per_s` | Nothing | Fixed latency cancels exactly; drift is measured |
| Infer absolute from daemon queues | — | **No** — ring is in the clock; grabber skew unknown |

**Ruling:** while MiSTer owns the only HDMI into the grabber, **absolute device lipsync is
unknowable**. That is acceptable. The tool must (and does) print
`calibration=NONE` + `tag=raw_uncalibrated` on every absolute median, and never present raw as
corrected. Slope and A/B deltas remain the publishable quantities.

Parent position on slope canceling fixed latency: **legitimate**, not a proxy — same physical
pairs, derivative removes the additive constant.

---

## Startup drops vs lipsync offset (H-DROP)

### What the 1 Hz telemetries established

On rk8 360 s 480p repeats (`tele_1/2/3` + `avsync_rep1/2/3`):

| run | startup_drops | transitions after first sample | median_offset_ms (raw) | steady residual/pub_miss |
|-----|--------------:|-------------------------------:|-----------------------:|--------------------------|
| rep1 | 15 | 0 (flat from wall_s≈7) | −316.0 | 0 / 0 |
| rep2 | 12 | 0 | −196.7 | 0 / 0 |
| rep3 | 18 | 0 | −196.0 | 0 / 0 |

Every drop is a **startup transient**. Ledgers close (`frames − presents − drops = 0`). The old
“steady-state sawtooth, one drop per 30 s” reading is **falsified** — it was inference from an
EOF total, not a time series.

### H-DROP (pre-registered)

`offset_ms ≈ a − (1000/24)·startup_drops` with frame quantum **41.667 ms** at measured 24.000 fps.

**What n=3 can and cannot establish**

- A 2-point fit is a **tautology** (zero residual by construction). It cannot validate H-DROP.
- The 3rd paired run is the first out-of-sample test (one residual degree of freedom).
- Confidence is the **OOS residual in ms** vs within-run median noise (~few ms), not “119 vs 125
  both fit in ±42”.

**Measured OOS (fit on rep1+rep2, predict rep3)**

| model | rep3 predicted | rep3 measured | residual |
|-------|---------------:|--------------:|---------:|
| free 2-pt slope ≈ −39.78 ms/drop | −435.3 | −196.0 | **+239.3 ms** |
| forced −41.667 ms/drop | −443.8 | −196.0 | **+247.8 ms** |
| 3-pt OLS | slope **+0.11** ms/drop, R²≈0.00002, pearson r≈0.005 | — | s_yx≈98 ms |

**Verdict: H-DROP REJECTED.** rep2 (drops=12) and rep3 (drops=18) share the same offset cluster
(~−196) despite Δdrops=+6 (expected ~250 ms under H-DROP).

Re-run:

```bash
python3 tools/analyze_drop_offset.py --defaults
# self-test: rc=0 on consistent synthetic H-DROP, rc=2 on broken OOS, rc=77 on missing
python3 tools/analyze_drop_offset.py --self-test
```

### Alternatives evaluated from the data (not speculation)

1. **One prefill quantum (100.0 ms)** — `kFeedTargetBytes=19200` at 48000·4 B/s
   (`mraudio_status.hpp`). Between-cluster jump |Δ(rep2−rep1)|=**119.33 ms**:
   - vs 100 ms → err **19.33 ms**
   - vs 3·frame (125 ms) → err **5.67 ms**
   - vs prefill+½frame (120.83) → err **1.5 ms** (descriptive only; not a mechanism proof)
   Steady-state `queued_ms_median` is **~100 ms on all three runs** (range 0.23 ms). Identical
   depth does **not** kill a one-shot **startup phase** equal to one quantum (depth ≠ content
   phase). It does kill “different steady prefill depth between runs.”

2. **`AV_PRESENT_LEAD_MS` / `av_drift_ms` deadband** — tele `av_drift_ms` medians sit ~−30 on
   all three runs. That metric is self-graded and was already proven blind to real lipsync; it
   does **not** move with the −316 vs −196 cluster split. Not an explanation of the jump.

3. **`AUDIO_DELAY_MS` / 117 ms hole** — none of these long runs were an adelay A/B; conf path
   cannot be blamed from this dataset. Unknown — would need silence-head + instrument A/B.

4. **Bistable absolute phase** — data favor **two offset modes** (~−316 and ~−196, gap ~120 ms)
   with startup_drops **not** selecting the mode (12 and 18 → same mode). Mechanism of the mode
   flip is **unresolved** from these files alone.

**Discrimination that actually works** (42 ms gate cannot separate 100 vs 125):

- **D1 (already live):** vary drops inside a mode — done; kills linear H-DROP.
- **D2:** change feed-target ms (50 / 100 / 150) across sessions; mode gap tracks feed → prefill
  phase; gap stays ~3 frames independent of feed → frame-quantum phase.
- **D3:** log clock-origin / hold-release / `pcm_silence_head` at start vs cluster id.

### Within-run structure (drops out as cause)

With steady drops flat, residual slope remains:

| run | per-pair slope ms/s | ρ₁ | SE_AR1 | t_AR1 | block10 slope | block10 t_AR1 |
|-----|--------------------:|---:|-------:|------:|--------------:|--------------:|
| rep1 | −0.108 | 0.34 | 0.014 | −7.9 | −0.106 | −2.81 |
| rep2 | −0.088 | 0.33 | 0.014 | −6.3 | −0.087 | −2.36 |
| rep3 | −0.093 | 0.39 | 0.016 | −5.7 | −0.087 | −2.27 |
| 480_330 | −0.094 | 0.50 | 0.019 | −5.0 | −0.088 | −2.04 |
| 240_330 | −0.122 | 0.45 | 0.014 | −8.8 | −0.139 | −3.70 |

All slopes negative and clustered. AR1-adjusted block-median t-stats still exceed ~2. Slow
drift ~0.09–0.12 ms/s × 320 s ≈ 30–40 ms matches early-vs-late fifth median gaps. **Not**
explained by drops.

### 240p arm

`avsync_240_330.json` median **−304.7** (near the −316 mode). **No telemetry** → startup_drops
**unresolvable**. Implied drops under a rejected 2-pt H-DROP invert (~14.7) are
`DEFAULT_ASSUMED` model fiction — do not publish as measurement.

### Two discrete offset clusters (post H-DROP)

Parent series (rk8; absolute = `raw_uncalibrated`). Tool auto-picks `/tmp/avsync_repN.json`.

| run | median_ms | 2-means | notes |
|-----|----------:|---------|-------|
| 480_330 | −318.0 | A | core-A |
| rep1 | −316.0 | A | core-A |
| rep2 | −196.7 | B | |
| rep3 | −196.0 | B | |
| rep4 | −304.7 | A | **shoulder-A** (~12 ms from core) |
| 240_330 | −304.7 | A | shoulder-like; excluded from sep by default |

- **Primary gap** is still ~120 ms (B vs core-A). Within-B spread **0.7 ms**; core-A spread **2.0 ms**.
- Shoulder (−304.7) sits on A’s side of the big gap but is **not** the same 2 ms core — full-A spread becomes **13.3 ms** once rep4 is in.
- Instrument SE(median) within a run ≈ **1.3 ms** → primary A/B split is not noise; shoulder needs more n before calling a third mode.

**Whole-series vs developing (measured on all current reps):**

- Pair-0 already on-cluster: core-A y0~−298…−282, B y0~−185…−172, shoulder y0~−275; |y0−med| ≪ |sep|/2.
- Cross-run `med_d` early/mid/late thirds **flat** across the ~120 ms pairs (e.g. rep2−rep1 all **113.333**; rep4−rep2 all **−117.333**; slope_d ~0.02 ms/pair).
- Rolling-median step-10 jumps max **~15–33 ms**, never ~120 → **no mid-run cluster flip**.
- Verdict: `SHIFT_KIND=WHOLE_SERIES_STARTUP_LEVEL` — level chosen at startup and held; slow −0.09 ms/s slope is separate residual drift.

**A,A,B,B(+A shoulder):** run order alone **cannot** distinguish bistable-random from one-way step. Need more repeats or intervention.

**100 ms prefill vs 125 ms (3×frame) — tight gate, not ±42:**

| sep definition | sep_ms | \|sep−100\| | \|sep−125\| | envelope gate |
|----------------|-------:|------------:|------------:|---------------|
| B − coreA (−317) | **120.67** | **20.67 → REJECT 100** | 4.33 (closer; not rejected at 3×2ms gate) | core spread 2 ms |
| B − fullA (incl shoulder) | 116.56 | 16.56 | 8.44 | full-A spread 13 ms → neither rejected |

`prefill+½frame=120.83` fits core sep to 0.17 ms — **numeric only, not a mechanism**.  
`tools/analyze_drop_offset.py --clusters-only` prints both.  
**E2 discriminator:** change feed-target ms (50/100/150) across sessions — sep tracks feed ⇒ prefill phase; sep stays ~3×frame ⇒ frame phase.

### `av_drift_ms` blindness (parent-measured, external)

Same three tele runs: internal `av_drift_ms` mean **−29.8 / −29.4 / −30.2** (range inside lead band) while external HDMI medians span **120 ms**. Confirms code argument (`AV_PRESENT_LEAD_MS` pins the band) with hardware. **Soak PASS on av-lock+av_drift_ms is not a lipsync claim.**

### Audio hold machine (source)

**Hold is NOT the 117 ms cluster discriminator (parent-measured, published miss).**
Instrumented daemon `5996385a`, opposite clusters:

| run | HDMI offset | cluster | held_ms | release→video | pcm→video | silence_head |
|-----|------------:|---------|--------:|--------------:|----------:|-------------:|
| 1 | −190.67 | B | **112** | 81 | 193 | 9 |
| 2 | −308.00 | A | **107** | 71 | 178 | 9 |
| Δ | **117.33** | | **5** | 10 | 15 | **0** |

H-DEV required origin/hold delta ≈ 117±30 ms between clusters; measured hold Δ=5 ms.
Session-start fields (geometry, vf, silence head, adelay, identity_skip, …) also **identical**
across clusters (parent P5 null). Hold source trace below remains valid plumbing; it is **not**
a fix justification for bimodality.

#### End-to-end (product RGB+audio path)

| Step | Where | What |
|------|-------|------|
| Arm closed | `media_player.cpp:2908-2911` | After ffmpeg spawn: `audioStartGate_=false`, `sessionOriginMonoMs_=-1`, start `audioPump` |
| Pump live | `:2064` | `audioActive_=true`; `audioBytes_=0` |
| Hold | `:2236-2356`, `:2315-2355` | While gate closed: `poll`+`read` PCM into `holdBuf`; **no** MrAudio `write`. Cap `kAudioHoldCapBytes` (2 s) with **ring drop HEAD** (`:2318-2325`). |
| Release trigger A (normal) | `:3475-3500` | On **first complete video frame** (`!avAudioReleased` after `++frameIndex`): latch `t0`, arm `sessionOriginMonoMs_`, `checkAudioReleaseOrigin(audioBytes_,0)`, **`audioStartGate_=true`**. Log `A/V audio_release … held PCM from content t=0`. |
| Release trigger B (degrade) | `:2250-2257` | If gated wait ≥ `kAudioHoldTimeoutMs` (**1200**, `av_clock.hpp:70`): pump opens gate **without video**. |
| Release trigger C (audio-only) | `:2583` | `skipRgb` path opens gate immediately (no hold). |
| Release trigger D (no audio pipe) | `:2914` | Gate forced open if no apipe. |
| Dump | `:2358-2371` | On first post-open pump iteration: `writePacedChunk` entire `holdBuf` from **begin()** (oldest = stream head unless HEAD was dropped), then live PCM. |
| Prefill at first write | `:2146-2157` | First MrAudio write past-biases `audioDue` by `kFeedTargetBytes` (~**100 ms**). Comment: **HOLD does NOT remove this prefill quantum.** |
| Present (later) | `:3526-3592` | `avDecide` may **Hold** video after gate is already open; `first_video_present` logs only when `presentCleanFrame` runs (`:3203`). Parent saw present **~86 ms after** release — consistent with post-gate pacing Hold while audio dumps. |

Constants: `kAudioHoldCapMs=2000`, `kAudioHoldTimeoutMs=1200`, `kFeedTargetMs=100` (`av_clock.hpp:65-70`).

#### What sets hold **duration**?

**Wall hold** ≈ time from first pump PCM (`first_audio_pcm`, `:2297-2311`) until trigger A or B opens the gate.  
**Buffer `held_ms`** = `holdBuf.size()` → ms via `checkAudioReleaseOrigin` (`av_clock.hpp:84-93`) — content depth in the ring buffer, not the mono wall delta (equal only if fill is real-time and no head drop).

There is **no fixed 120 ms timer** on the success path. Duration is a **race**: ffmpeg audio availability vs first full video frame assembly (or 1200 ms timeout).

#### Can it be bimodal (≈0 vs ≈120)?

| Trigger | When | held outcome |
|---------|------|----------------|
| A first complete frame | normal cast | continuous: whatever PCM arrived before frame1 (can be ~0 if video wins race, or 100s of ms if audio leads) |
| B timeout 1200 ms | no video in 1.2 s | large hold / degrade — **not** the 120 ms cluster scale |
| C audio-only | skipRgb | ~0 by construction |
| D no audio | — | N/A |

So product path has **two code triggers** (frame vs timeout), not a 0/120 pair. A **~120 ms mode** is compatible with a typical audio-leads-first-frame race; a **~0 ms mode** is compatible with video winning that race. That is a **timing race on one trigger (A)**, not two discrete release machines at 0 and 120. Whether silicon clusters map 1:1 to held_ms is **unproven** until parent pairs them (n=1 so far).

#### Is held PCM replayed from content t=0? **Yes (if no HEAD drop)**

- While gated, PCM is only appended to `holdBuf` (`:2315-2355`); `audioBytes_` increments only in `writePacedChunk` (`:2144`) after gate open.
- `checkAudioReleaseOrigin` requires `audioBytesAtRelease==0` (`av_clock.hpp:88-92`); else ERROR “hold bypassed”.
- Dump writes `holdBuf` from `begin()` (`:2362-2365`) = oldest samples = stream head unless cap dropped HEAD (`:2318-2325`).
- Log text is literal: “held PCM from content t=0” (`:3515`).

**Sticky origin implication (mechanism, not silicon proof):** at gate open, video is at `frameIndex=1` → `frameContentMs(1)=1000/24≈41.7 ms` (`av_clock.hpp:15-21`). Dump submits the **entire** held content (e.g. 0…held_ms) into MrAudio in a burst (past-bias allows no sleep until prefill caught up). Audible timeline then runs with that content already queued; pacer uses **raw** `audibleClockMs` with **no origin subtract** (`:3534-3537`, `:3243`). Startup drops may repay some lead (`avDecide` Drop when drift large); any **unpaid** remainder is a **permanent content offset** for the session (same class GStreamer calls a permanent offset until flush/seek).

Host model of residual lead after hold dump: `simulateHoldReleaseRace` (`av_clock.hpp:345-370`).

#### Origin latch / rebase

| Event | Behavior |
|-------|----------|
| Gate open / first complete frame | `t0` re-latched; `sessionOriginMonoMs_` set once (`:3488-3494`). **Physical start, not co-arm subtract** (`:3487`, header `:386-390`). |
| Pause | `t0` adjusted by pause duration (`:3288-3290`) — wall clock only when not on audio. |
| Seek / new play | New session: gate closed again (`:2910-2911`, kill path `:1070-1071`). |
| Steady state | **No** GStreamer-style discont rebase. `coArmedClockMs` is **DEPRECATED unit-only** (`av_clock.hpp:34-36`). Product: raw audible clock. |

#### Cheapest falsifier (parent hardware — agent must not run)

On each instrumented cast, parse:

```text
Δ_hold_wall_ms = mono(A/V audio_release) - mono(first_audio_pcm)
held_ms_buf    = from pump "audio release … held_ms=" OR held_bytes/192
cluster        = HDMI median vs A≈-314 / B≈-197
```

| If | Conclude |
|----|----------|
| Δ_hold_wall (or held_ms_buf) tracks cluster with slope≈1 and Δ≈117 between A/B | hold (or dump race) is the cluster mechanism |
| hold stats identical across A and B (within ~5 ms) while HDMI sep stays 117 | **kill** hold-duration suspect; look post-release (prefill burst / present lag) |
| reason=`hold_timeout` ever on rk8 | separate degrade path — exclude from A/B |

Do **not** use `av_drift_ms` (proven blind). Hold pairing **already ran** — falsified.

**Parent measurement (instrumented daemon `5996385a`, n=2 opposite clusters) — H-HOLD miss published:**

| run | HDMI offset_ms | cluster | held_ms | release→video | pcm→video | pcm_silence_head_ms |
|-----|----------------|---------|---------|---------------|-----------|---------------------|
| 1 | −190.67 | B | **112** | 81 | 193 | 9 |
| 2 | −308.00 | A | **107** | 71 | 178 | 9 |
| Δ | **117.33** | | **5** | 10 | 15 | **0** |

Pre-registered H-DEV required origin delta ≈ 117±30 ms; measured hold Δ≈5 ms (~7× outside band). **Hold is not the 117 ms discriminator.** Delivery geometry / filter graph / silence head also identical (parent P5 null). Origin record fields do not separate clusters.

### MrAudio → FPGA handoff — where daemon control and observability END

Product audio path (header `media_player.hpp:2-3`, arch diagram `docs/architecture.md`):

```text
ffmpeg s16le 48k stereo
    → audioPump writePacedChunk
    → ::write(/dev/MrAudio)          ← LAST userspace store the daemon performs
    → MiSTer MrAudio DMA ring (kernel)
    → SPI toward FPGA / sys audio mix  ← daemon does not schedule this
    → HDMI / analog out
```

#### Last thing the daemon **controls**

1. **Whether** to write and **which PCM bytes** (`media_player.cpp` `writePacedChunk`, `::write(out, …)` after gate open).
2. **Software pacing** of those writes: `audioDue` + `sleep_until`, rate from `feedRateBytesPerSec(nominal, queuedEma)` (`mraudio_status.hpp:133-145`), seed `AUDIO_CLOCK_PPM`.
3. **Optional F2 fallback** only if MrAudio open fails: `FpgaSpi::sendPcmChunk` → `sendFileTx` index 2 (`fpga_spi.cpp:1823-1832`; pump prefers MrAudio and skips F2 when Mr works — `media_player.cpp:2036-2040`).

#### First things the daemon does **not** control

Quoted from in-tree driver notes (`mraudio_status.hpp:4-14`, expanded `docs/MILESTONE_AVSYNC_SEEK.md` “wrong clock” section):

- `/dev/MrAudio` is a **512 KB DMA ring** (`kMrAudioRingBytes`, `mraudio_status.hpp:33`).
- **`write()` never blocks and never consults the read pointer** — copy into ring, wrap, return. Lab: 10 s PCM accepted in 116 ms.
- **FPGA/SPI drain schedule** (when the consumer advances `rptr`) is **not** set by misterplexd.
- **Sys audio mix / HDMI audio packet phase** relative to video scanout — outside this process (`osd_menu.hpp:12-16`: remaining path difference is “FPGA output, HDMI, and the display… cannot be measured from the ARM”).

So: daemon chooses **byte stream + feed rate into the ring**. Hardware/driver choose **when those bytes become sound** on the wire.

#### Where observability **ends** (precise)

| Observable | How | Cadence / limit |
|------------|-----|-----------------|
| Bytes **submitted** | `audioBytes_ += n` on successful write intent (`writePacedChunk`) | every chunk |
| Ring **depth** `len=(wptr-rptr)` | `readMrAudioQueuedBytes`: open MrAudio **O_RDONLY**, `read` status line, `parseMrAudioQueuedBytes` (`media_player.cpp:2020-2029`, `mraudio_status.hpp:18-22,39-69`) | **every 4th chunk** (~80 ms), not per sample |
| “Heard” clock used by pacer | `audibleClockMs(written, queued) = (written−queued)/192000` (`mraudio_status.hpp:76-82`) | same sample rate as `len`; assumes **nominal 48 kHz** drain |
| Overwrite risk | log if `queuedEma > 3/4 ring` | coarse |

**Not observed / not logged by this daemon (from source) before handoff logs:**

- Absolute **wall time of first DAC/HDMI audio sample** (no HW PTS back to userspace beyond `len`).
- **Phase** of FPGA audio clock vs video pixel clock / vsync.
- Per-sample SPI completion; `comp:` was format-only until `ring_at_open` / `ring_after_first_write` logs.
- Anything after SPI leave (core mix, HDMI A/V relative skew in the RBF).

**FPGA consumer (in-tree `fpga/Plex_MiSTer/sys/alsa.sv`) — mechanisms the daemon does not schedule:**

```verilog
// alsa.sv:116-119 — first time rptr!=wptr after reset, SNAP rptr to wptr
// (skip whatever was already queued), then set got_first.
else if(buf_rptr != buf_wptr) begin
    if(~got_first) begin
        buf_rptr <= buf_wptr;
        got_first <= 1;
```

```verilog
// alsa.sv:149-153 — sample CE is free-running NCO at 48000 + hurryup
acc <= acc + 48000 + {hurryup,6'd0};
if(acc >= CLK_RATE) begin ... ce_sample <= 1;
```

```verilog
// alsa.sv:95-103 — hurryup 0..4 from buffer fill bits (rate bend, not daemon-set)
if(len[18:14] && (hurryup < 1)) hurryup <= 1;
...
if(!len[18:10]) hurryup <= 0;
```

`got_first` clears only on `reset` (`alsa.sv:86-91`). Across sessions without that reset, snap does not re-fire; residual ring state can persist. **These are source-visible mechanisms past the daemon write. They are NOT a measured cause of the 117 ms clusters.**

`audio_out.sv` mixes `alsa_l/r` with core audio into I2S (`sys_top.v:1579-1610`). Filter enable ramps `a_en1`/`a_en2` after **audio_out reset only** (`audio_out.sv:176-196`) — another fixed post-reset path latency class, not session-logged by the daemon.

**Product logs (post this instrumentation):**
- `media: MrAudio ring_at_open mono_ms=… rptr=… wptr=… len_B=… len_ms=…`
- `media: MrAudio ring_after_first_write mono_ms=… written_B=… rptr=… wptr=… len_B=…`

**Implication for the 117 ms defect (bounded claim):** parent showed session-start daemon fields and hold stats do not separate clusters. The handoff model says a **fixed or session-random phase** in the **post-write** path (ring start phase, FPGA drain, HDMI) would be **invisible** to every signal built from `written`, steady `len`, `frameIndex`, and `av_drift_ms` **if that phase is constant for the session and similar in steady `len`** — because `audibleClockMs` subtracts depth and `av_drift_ms` only compares that clock to `frameIndex`. That is a **compatibility** statement with blindness, **not** a location of the cause. Locating it needs an observation **outside** this set (grabber already is; on-device would need a new sensor, e.g. core-side marker or external loopback). Pair `ring_at_open` / `ring_after_first_write` across A/B — if identical while HDMI sep stays 117, ring-depth path is weaker as discriminator.

#### Held PCM from content t=0? / origin rebase? (unchanged)

- **Yes** dump from `holdBuf.begin()` after `audio_bytes_at_release==0` (see hold section) — independent of cluster falsification.
- **No** steady-state origin rebase; latch once at first complete frame; seek/new play resets gate.

#### Cheapest next falsifiers (still parent-owned hardware)

1. Log **first N** `len`/lat samples with `mono_ms` for cluster A vs B (depth **trajectory** at open, not only steady 100 ms) — if identical through first 500 ms, ring depth path is weaker as discriminator.
2. Keep using **HDMI instrument Δ** as ground truth; do not promote `av_drift_ms` or origin-record equality into “in sync”.
3. Do **not** treat hold redesign as the 117 ms fix (measurement already killed that).

### w-geom FPGA path source (117 ms clusters) — hardened

Full note: `.agent-work/w-geom/fpga-av-path-117ms.md`.

| Q | Answer |
|---|--------|
| Audio two-state @ 117 ms? | **NO (correct negative).** Quanta: sample **0.020833 ms** (`alsa.sv` 24576000/48000); I2S frame same; `a_en2` mute **170.667 ms after audio_out reset only**; `got_first` one-shot variable discard. No fill-threshold start. |
| Audio mailbox? | **NOT-FOUND.** `0x300FF12C` (“PLXD4”) = **high word of PLXD** = `frames_done` (video), not audio. |
| Video / 3 content frames? | **REJECTED:** 3×24 fps = **125.0 ms**, \|125−117.10\|=**7.9 ms**. |
| Video / 1 vsync? | Exact **T_disp = 638×524/20e6 = 16.715600 ms** (colorbars+20 MHz). One-frame late ≠ 117 ms. |
| Video / 7×T_disp? | **7×T = 117.009200 ms** (err 0.091 ms vs 117.10) — arithmetic match only; **no RTL bistable for 0 vs 7**. Measure `frames_done` lag. |
| Observe | `frames_done=(devmem 0x300FF12C)>>16`; Δ(audio_release→first frames_done++) / 16.715600 → N; A vs B. |

**Audio in-tree RTL eliminated as 117 ms bistable. Video open until lag measured. Kernel MrAudio driver still out of repo.**

## Observability boundary — definitive Q1–Q4 (w-avsync)

Full CITED/NOT-FOUND table: `.agent-work/w-avsync/observability-boundary.md`.

| Q | Answer (one line) |
|---|-------------------|
| 1 Path | `::write(/dev/MrAudio)` → 512 KiB kernel ring → SPI → `sys/alsa.sv` (DDR PCM + NCO) → `audio_out` → I2S. F2 `audio_fifo` **off** product path when MrAudio works (`media_player.cpp:2062-2063`). |
| 1 Readable | **YES:** status `rptr,wptr,len,comp` (`mraudio_status.hpp`). **NO:** `got_first`, NCO phase, HDMI audio phase. Driver `.c` **NOT-FOUND** in repo. |
| 2 Period | CITED sample period **20.833 µs** (`alsa.sv` CLK_RATE/48000). **NOT-FOUND** ~117 ms audio start quantum. `a_en2` mute ≈170.7 ms **after audio_out reset only**. |
| 3 Unproven-identical readable | Absolute **rptr/wptr**, **comp**, PLXD **frames_done**, early **len** trajectory. Steady `len≈100 ms` already identical both clusters. |
| 4 Instrument | `logMrAudioHandoffAt` at `audio_release` + `first_video_present`; `early_traj` chunks 0..15; existing open/first_write snaps. ARM md5 see commit. |

**Falsifier:** A/B `rptr` Δ ≈ 22464 B (117 ms × 192000 B/s) at same handoff tag **supports** ring-phase track; **identical** snaps + HDMI sep 117 **kills** MrAudio-visible state → look past SPI / video `frames_done` lag / out-of-repo driver.

Hold still dumps content t=0; origin not rebased mid-play; hold **not** 117 ms cause (parent).
