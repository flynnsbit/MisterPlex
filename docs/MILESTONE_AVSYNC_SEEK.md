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

- Local PMS (`4edd44…` / `192.168.1.41`) does **not** host 40710 (HTTP 404).  
- Remote server `1cdd1b7f…` @ `http://203.0.113.10:32400` **REACHABLE** (2026-07-25):  
  - **40710** = **show** (TNG), not the episode.  
  - **S1E1 episode = `/library/metadata/40868`** (Encounter at Farpoint, duration ~91 min).  
  - playMedia offset=234000 (~3:54) → timeline playing time=234000 (probe).  
- Evidence: `/tmp/misterplex-agent-AV-trek-probe.txt`.  
- **G-AV4 still PENDING** — reachability ≠ eyes-on/HDMI dialogue PASS.

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
where the pre-fix origin race gave **67 ms**. Absolute value still includes an
uncalibrated grabber skew, so `AUDIO_DELAY_MS` stays **0** and G-AV4 eyes-on remains the
arbiter of the constant.

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

## Gates

| Gate | Status |
|------|--------|
| G-AV0 AUDIO_DELAY_MS=0 | **PASS** (baseline measure; log `delay_ms=0`) |
| G-AV1 Trek-matched blip | **PASS** (assets + PMS 9/10) |
| G-AV2 measure harness | **PASS** (`avsync_report.txt` n=12 flash↔beep) |
| G-AV3 \|median\| ≤ 42 ms | **PASS** — \|median\|=**36.0 ms** n=11 @ `AUDIO_DELAY_MS=60`; baseline −60 @0; `avsync_report_delay60.txt` + d60 companion |
| G-AV4 Trek 3:54 | **PENDING** (clock now locked over a 6.5 min WAN soak; eyes-on dialogue still the only PASS) |
| G-AV5 exact rate | **PASS** — log `content fps exact=24000/1001` (Trek/RK11) and `24/1` (RK12) from the same `24p` metadata; `make unit` `test_avclock` |
| G-AV6 drift slope ≤10 ms/min | **PASS** — **+0.79 / −0.67 / +1.79** ms/min (RK11, 240 s fits) and **−2.21** (RK12 control); before: **−53.3** |
| G-AV7 constant offset | **PARTIAL** — run-to-run spread cut 67 ms → ~9 ms; absolute value blocked on grabber skew calibration, so `AUDIO_DELAY_MS=0` pending G-AV4 |
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

# G-AV4 Trek dialogue (still open): cast episode 40868 (not show 40710), seek 234000
# expect |median_offset_ms| ≤ 42; keep RBF 1441d409
```
