# Session 2026-08-16 — PMS movie/TV lipsync (full record)

Private lab record. **Not for `origin` / GitHub.** Lives under `Memory/` (gitignored on the public MisterPlex tree). Copy this worktree including `Memory/` to node-worker1.

Pickup for the next Grok: `Memory/lab/status/GROK_PICKUP_NODE_WORKER1.md`.

## Standing (still in force)

- **L57** — no mailbox/QSF/PHYS experiment loops unless at the end for a few frames. Write FPGA as product from MiSTer-devel + Freddo. Small-test then MiSTer play. One exclusive of a real design.
- **L58** — grab HDMI yourself. Do not ask the user to look at the TV.
- **SKIP_RESTORE=YES**. Do not restore true480 `07f54d9f` as the 720p product.
- Product tree is **`/home/shawn/Projects/MisterPlex-wt-480p-lessons`** branch **`lessons/true480-720p24`**, not dirty decode `main`.
- Host `192.168.1.183` pass `1`. Identity MiSTerPlex / misterplex / HTTP 3005.
- Evidence only. Never invent BUILD_OK / 23.9 / official ±42. Soft-skip ≠ PASS.
- No `/bin/fpga`. No named `load_core` of `Plex.720p24.*`. No second Quartus of the live tree. No mid-fit RTL.
- Display must change the MiSTer raster or the setting is meaningless.
- User 2026-08-16: **no documentation mill**. Code, test on hardware, code, test.
- User: **audio is still out of sync**. Do not claim PASS from daemon `av_drift_ms=0`.
- User: default video/audio delay **0 ms** so they can nudge if slightly off.

## What the user asked (this conversation, in order)

1. Loop until resolved and tested with user-type PMS movies and TV.
2. Audio seconds ahead on Trek (later: 4–5 s; then “looks good”; then “off again”).
3. Keep going / ignore chatter / you were making progress.
4. “You are just looping a short video, are you getting somewhere?”
5. Build a Trek-like flash+beep test, default delay 0, loop until resolved, no docs.
6. Save the entire session to permanent memory in the MisterPlex tree; check in harnesses + Grok pickup; moving Grok to tmux on **node-worker1** and moving the HDMI–USB dongle there.
7. Put everything in the monorepo; keep it **private** so it can move with the machine.

## Hardware / accounts

| Role | Value |
|------|--------|
| MiSTer | 192.168.1.183 root / 1 |
| Product RBF | `/media/fat/Plex.rbf` md5 **03f1b95ac67a568f24193234ea8cb072** |
| Utility bak (do not flash as 720p) | `_Utility/Plex.rbf` / true480 **07f54d9f** |
| Daemon path | `/media/fat/misterplex/bin/misterplexd` |
| Conf | `/media/fat/misterplex/misterplex.conf` |
| Supervise | `/tmp/misterplexd_supervise.sh` + `MPX_INPROC_DECODE=1` |
| Lab PMS | `http://192.168.1.24:32400` — same host as **node-worker1** |
| Home PMS | `http://75.30.183.153:32400` — real Trek |
| Tokens | `Memory/lab/local/secrets.env` |
| HDMI dongle | MacroSilicon `534d:2109` MS2109. On old Grok host: `/dev/video4`. On node-worker1: **`/dev/video0`**. Audio `hw:CARD=MS2109,DEV=0`. |
| Farm grab | `scripts/hdmi_grab_farm.sh` |

## Silicon timeline (honest)

| Binary | What it is | Result |
|--------|------------|--------|
| `f89b5e08` | fps-match, OSD 240p transcode | PMS `videoResolution=320x180/192`, pipe, ~20 fps |
| `399dd5bc` | L4 always `{1280,720}` content ladder | Request 720p even if OSD word is 240p |
| `788e5ee6` | Linked ARM libav **with** HTTP/network | `network protocols disabled` still, or **glibc NSS abort** (`dl-call-libc-early-init`) if avformat touched HTTP |
| `5c2d730d` | Tried HTTP inproc | Daemon **crash** on getaddrinfo / static glibc |
| `120927e5` | File-only libav (`/tmp/ffmpeg-arm-u1`) + remux HTTP→annex-B fifo | Inproc works on PMS. First BBB ~22 fps. |
| `347f9af6` | No seek on fifo + hold audio to `presentCount/fps` | Seek at offset=234 had forced **pipe=1 @ 18.8 fps**, audio **+12 s** vs pictures |
| `885621ad` | `fastSeek=0` | 4–5 s GOP snap (audio at 234 s, video at next IDR) gone on daemon clock |
| `19dc3516` | Skip 4:3 fit on 1280×720 request | Farpoint **1280×720** inproc, pfps **23.7** at 2–4 min, `audio_s` within ~70 ms of `frames*1001/24000` |
| `a77efa31` | `presentLeadMs_` default **0**, native-1280 HDMI lag default **0** | Built, **not deployed**. Box conf still 100/40. |

RBF never changed this session: **03f1b95a** (720p24 Freddo, V_TOTAL 750, beam ~24.07 Hz). HDMI scaler still CEA 720p60 `74.25 MHz`. unique24 = pfps **and** hw_fps ≥ 23.9. **Not claimed.** Official HDMI ±42 **not claimed.**

## Bugs that were real

1. **24p from Plex is 23.976** (`24000/1001`). Pacing 24/1 drifts ~1 ms/s (~5.5 s in a 91 min film).
2. **OSD 0x0000 → 240p ladder** → 320×180 transcode + scale. Fix: L4 always requests 720p.
3. **Inproc cannot open HTTP** — ARM libav was `--disable-network`. Linking network + static binary **crashes** on getaddrinfo.
4. **Product path:** box ffmpeg remux HTTP → `/tmp/mplex-inproc.h264` fifo (annex-B, `h264_mp4toannexb`); inproc decodes the **file** fifo. Audio stays `spawnAudioOnly` from HTTP.
5. **`av_seek_frame` on the fifo** when `offset=234000` → open fail → pipe → 18.8 fps → audio wall-48 kHz **~12 s ahead**.
6. **`fastSeek=1`** → video starts at next keyframe, audio at exact offset → **~4–5 s** audio ahead. User heard this. `fastSeek=0` now.
7. **Audio pump wall-paced 48 kHz** independent of present rate. Hold: do not let `audio_s` lead `presentCount * den/num` by more than 80 ms.
8. **4:3 Trek fitted to 960×720** then nearest-up to 1280. Skip fit when max ≥ 1280×720. HDMI 720p is treated as 16:9.
9. **Daemon lock ≠ lipsync.** User still heard it off. Next truth is HDMI flash vs beep with delays at 0.

## Code landed (worktree, vs tag `v0.5.0` / `af1ca9bc`)

- `arm/misterplexd/plex_resolve.cpp` — `24p`/`film` → 24000/1001; `30p` → 30000/1001; `capExactFpsToMaxHz` (60→30); `fastSeek=0`; no 4:3 shrink at 1280×720.
- `arm/misterplexd/main.cpp` — L4 `contentResolutionForNextPlay` → `{1280,720,"720p",20000}`; play-file fps rational + cap 30.
- `host/libmisterplex/source_aspect.hpp` — `fpsTokenFromFfmpegProbeText`.
- `arm/misterplexd/av_inproc_decode.cpp` — file-only; skip seek on FIFO; reject all `://` except we never open HTTP.
- `host/libmisterplex/av_inproc_decode.hpp` — `headers` field (unused for file fifo).
- `arm/misterplexd/media_player.cpp` — remux fifo, `F_SETPIPE_SZ` 1 MiB, `iopts.startMs=0` on fifo, audio hold to presented frames, HDMI lag default 0.
- `arm/misterplexd/media_player.hpp` — `spawnHttpRemuxMpegts`; `presentLeadMs_=0`.
- `tests/unit/test_resolve.cpp` — 24p, cap, fastSeek=0, 720p fit stays 1280×720.
- `tests/unit/test_av_inproc_decode.cpp` — HTTP rejected (file-only).
- Fixture: `assets/avsync/trek_blip_720p23976.mp4` — 1280×720 **24000/1001**, flash+beep / 1 s.
- Measurer: `scripts/measure_flash_beep.py` — HDMI capture → median beep−flash ms.

## PMS slate

**Lab PMS** (192.168.1.24, library “MiSTerPlex Tests” key=2): rk=140 film 23.976; rk=7 720p 24.000; rk=143 Grid720 30p; rk=142 1080p 29.97; rk=82 60p (cap 30); rk=10 BBB 24.000. No real Trek there.

**Home PMS** (75.30.183.153): TNG S1E1 Encounter at Farpoint **rk=40868**, 1440×1080 4:3 **HEVC** 23.976, ~91 min (`dur=5484416` ms). Transcode to H.264. Play at **offset=234000** (~3:54). That is the user title.

`scripts/plex_browse.sh --player 192.168.1.183:3005 --base BASE --token TOKEN [--offset MS] play RK`

## How we tested (and what was wrong with it)

Repeated 20–90 s plays of Farpoint **at 3:54** plus HDMI stills. Looked like a short loop. Session-average pfps climbed 23.2 → 23.7 over minutes. Last-second produce was ~25 fps after warmup. **User rejected “fixed”** because ears said no.

Source-file self-measure of the new 23.976 blip (decode to 60 Hz gray + PCM) reported median **−16.7 ms** (60 Hz quantize). That is the **file**, not HDMI.

## Next test (do not skip)

1. Delays all **0** in conf + deployed `a77efa31` (or rebuild).
2. Play `trek_blip_720p23976.mp4` ~20 s.
3. HDMI mkv on node-worker1 `/dev/video0` + MS2109.
4. `python3 scripts/measure_flash_beep.py`.
5. Fix the path so median ≈ 0 at delay 0.
6. Then Farpoint. Then leave it playing.

## ARM ffmpeg

- File-only (link this): `/tmp/ffmpeg-arm-u1/prefix` — no network, demux mov+h264, decode h264.
- Network rebuild (do **not** link into static misterplexd): `/tmp/ffmpeg-arm-u1-net/prefix`.
- Box ffmpeg (has HTTP): `/media/fat/misterplex_v2/bin/ffmpeg` — remux only.

```
make -C /home/shawn/Projects/MisterPlex-wt-480p-lessons arm-plexd \
  ARM_FFMPEG_PREFIX=/tmp/ffmpeg-arm-u1/prefix
```

## Deploy recipe (ARM only)

```
export SSHPASS=1
# park supervise, TERM misterplexd, scp to .../misterplexd.new, mv, chmod
# restore supervise with MPX_INPROC_DECODE=1
# ONE load_core /media/fat/Plex.rbf if CORENAME!=Plex
```

## Cancelled

2-minute multi-agent scheduler (`01a00aea13bb`) — it spawned docs workers. Do not restart it.

## Published release (already on GitHub, earlier)

`v0.5.0` on `lessons/true480-720p24` (`af1ca9bc` + `5060d8fe`). Packaged RBF 03f1b95a. **Does not** include this session’s remux/hold/fastSeek/1280-keep/delay-0 work.
