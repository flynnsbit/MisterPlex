# p480-verify — 480p selectable option vs 240p baseline

- **TS_UTC**: 2026-07-30T16:38:48Z … 16:44Z
- **SOURCE_SHA**: `394d5ae19a8cead6aba4c6a9747bd31a8e63ace2`
- **Device**: MiSTer `192.168.1.183`
- **Daemon**: v10 md5 `fb9f76192a8f7d248411c2ab2b332542` (prefix fb9f7619)
- **RBF**: md5 `14eaeff3270a6f59a434e0f777ed823d` (prefix 14eaeff3) — **unchanged**
- **CORENAME**: Plex throughout measurement window
- **Default**: left at **240p** (bit4=0)

## Step 0 — PMS / real cast

| Check | Result | Artifact |
|---|---|---|
| Local PMS `127.0.0.1:32400` | **UP** HTTP 200, machineId `bf36a3ad…` | `02_pms_identity.xml` |
| Conf PMS `YOUR-PLEX-SERVER:32400` (from live conf) | **UP** HTTP 200, machineId `4edd44aa…` (matches user-stated server) | `14_real_cast_window.out` R0 |
| Live conf `PLEX_BASE` | `http://YOUR-PLEX-SERVER:32400` | `00_device_snapshot.txt` |
| Local library | empty (size=0) | `08_local_lib_all.xml` |
| Conf PMS library | Movies=7 items (sync blips) + TV | `11_movies_sample.xml` |
| GDM UDP 32412 | **HIT** len=283 `Resource-Identifier: misterplex-dev` | `10_gdm_probe.txt` |
| PMS `.41/clients` | **HIT** MiSTerPlex @ 192.168.1.183:3005 | `12_41_clients.xml` / R1 |
| Direct `playMedia` real media rk=6,12 | **HIT** state=playing, frames advance, not testsrc | `14_*.out` `16_*.out` |

### Does not stick — measured notes

Daemon log when CORENAME was MENU (prior supervise restart at 14:33Z) quotes:

`misterplexd: ERROR Plex core NOT loaded (CORENAME=MENU) at startup — PRESENT=fpga so /resources still advertises this player but HDMI/presents cannot work. ... Casting now will look like it doesn't stick.`

With CORENAME=Plex now, product-like playMedia does stick. Full Plex Web/TV UI cast was not driven (API path only). GDM discovery works.

## Step 1 — p480-verify-chain (five answers)

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1 | Live OSD_CONTROL | **OSD_CONTROL=1** | conf + boot log |
| 2 | Live RBF carries v7 CONF_STR / O[4] | **Indirect YES**: Plex_v7.CFG exists. Plaintext CONF_STR strings NOT in RBF bitstream. set_status --confstr empty. | 15_*.txt |
| 3 | Toggle O[4]; daemon sees change | **YES** | quoted lines below |
| 4 | DECODE_ALLOW_LAB_480P absent blocks OSD 480p? | **NO — OSD path works without flag** (ALLOW_count=0) | bit4_1 play |
| 5 | OSD 640x480 -> coded 624x480? | **YES intentional** | label 624x480, PMS videoResolution=624x480, ffmpeg scale=624:480 |

### Quoted content-resolution lines (falsifier)

```
misterplexd: content resolution=320x240 source=OSD O[4] status_word=0x4000 weak=320x240 bitrate=1000
misterplexd: content resolution=624x480 source=OSD O[4] status_word=0x4010 weak=624x480 bitrate=2000
misterplexd: content resolution=320x240 source=OSD O[4] status_word=0x0000 weak=320x240 bitrate=1000
```

status_word changes 0x4000 -> 0x4010 -> 0x0000 (bit4 0->1->0).

## Step 2 — metrics (REAL media, not testsrc)

Media: PMS .41 /library/metadata/12 Sync 24000 Long Blip 24fps, dur=360021ms, transcode=1.
Method: one wall window, P = 100 * dticks / (HZ * dwall), HZ=100, no fps scaling (play_cpu_sample.py).

| Tier | status_word | coded | bitrate | wall_s | PLAY_P_ONECPU | late pfps | drops | av_drift_ms | DDR frame_tx ms |
|---|---|---|---|---|---|---|---|---|---|
| 240p bit4=0 | 0x4000 | 320x240 | 1000 | 15.031 | **11.443%** | ~23.1 | 1 | ~-24..-26 | mostly **4** |
| 480p bit4=1 | 0x4010 | 624x480 | 2000 | 15.077 | **25.536%** | ~23.0 | 5 | ~-26..-28 | **8-11** |
| 240p restored | 0x0000 | 320x240 | 1000 | 15.032 | **11.509%** | ~23.3 | 1 | ~-31 | mostly **4** |

Additional short cast rk=6: PLAY_P_ONECPU=**12.526%** @ 320x240 (wall 20.039s).

### Pre-registered predictions vs actual

| ID | Prediction | Result |
|---|---|---|
| P1 | Real cast succeeds @ 240p | HIT |
| P2 | content resolution log + status_word changes | HIT |
| P3 | OSD 480p works without DECODE_ALLOW_LAB_480P | HIT |
| P4 | 240p CPU ~10-20% | HIT (11.4-12.5%) |
| P5 | RBF plaintext CONF_STR | MISS — no plaintext; v7 CFG only |
| P6 | UI does not stick may still exist | UNTESTED (API works; MENU-core log path documented) |

### Extra findings (not fixed)

- set_status --confstr empty on this RBF; tool fps_sel decode still uses pre-v7 O[5:4] labels (display-only).
- 480p is **viable** at ~2.2x 240p one-cpu and ~2x DDR push ms; pfps still ~content 24 with av-lock. Higher startup drops (5 vs 1).
- Conf TRANSCODE_PROFILE=480p naming while content tier is OSD-driven.

## Device left as

| Item | Value |
|---|---|
| daemon md5 | fb9f7619… |
| RBF md5 | 14eaeff3… |
| CORENAME | Plex |
| n_daemon | 1 (+ supervise) |
| PRESENT_PROFILE | 0 |
| OSD_CONTROL | 1 |
| Content tier | **240p** (bit4=0 restored) |

No RBF rebuild. No daemon binary change.
