# Grok pickup — node-worker1 + HDMI dongle

**Read this first** on the new tmux session. Full session record:
`Memory/lab/status/SESSION_2026-08-16_PMS_LIPSYNC.md`

Do **not** push that file or `Memory/lab/local/secrets.env` to `github.com/flynnsbit/MisterPlex`.
`Memory/` is gitignored on the public tree. Copy the worktree (including `Memory/`) privately.

## Where you are

| | |
|--|--|
| SoT worktree | `/home/shawn/Projects/MisterPlex-wt-480p-lessons` |
| Branch | `lessons/true480-720p24` |
| Public origin | `github.com:flynnsbit/MisterPlex` — **do not push tokens** |
| Dirty decode `main` | `/home/shawn/Projects/MisterPlex` — **not** the product tree |
| MiSTer | `192.168.1.183` root / pass `1` |
| HDMI eyes | **this machine** once the dongle is here: MacroSilicon `534d:2109` |
| Device | `/dev/video0` (metadata `/dev/video1`). Was `/dev/video4` on the old host. |
| Audio | `hw:CARD=MS2109,DEV=0` |
| Recipe | MJPEG `1280x720` only. YUYV corrupts. Discard first still (~7 kB / `e74e3559`). |

Standing: **L57** no experiment loops. **L58** grab glass yourself. **SKIP_RESTORE=YES**. Never restore `07f54d9f` as 720p. No `/bin/fpga`. No named `load_core` of `Plex.720p24.*`. Evidence only. Soft-skip ≠ PASS. Do not invent 23.9 or official ±42.

## Live silicon (last seen 2026-08-16 ~15:10Z)

- RBF `/media/fat/Plex.rbf` md5 **`03f1b95a`**
- Box daemon **`19dc3516`** (1280-keep + remux inproc + audio hold + `fastSeek=0`)
- Local unreleased ARM **`a77efa31`** (defaults: present lead 0, HDMI audio lag 0) — **not deployed**
- Box conf still had `AV_HDMI_AUDIO_LAG_MS=100` `AV_PRESENT_LEAD_MS=40` `AUDIO_DELAY_MS` unset
- Last CORE was **MENU** (Farpoint play had ended)
- User: **audio still out of sync**. Daemon `audio_s ≈ frames/fps` is **not** a glass PASS.

## Open work (do this, in order)

1. Confirm dongle: `v4l2-ctl --list-devices` → MS2109 on `/dev/video0`. `arecord -l` → MS2109.
2. Load Plex once: box on MENU → `timeout 3 sh -c 'printf "load_core /media/fat/Plex.rbf\n" > /dev/MiSTer_cmd'` — only `/media/fat/Plex.rbf`.
3. Deploy **`a77efa31`** (or rebuild) with conf:
   ```
   AUDIO_DELAY_MS=0
   AV_HDMI_AUDIO_LAG_MS=0
   AV_PRESENT_LEAD_MS=0
   MATCH_SOURCE_HZ=on
   DECODE=1280x720
   MPX_INPROC_DECODE=1
   ```
   Park supervise, TERM daemon, scp `.new`, mv, restore supervise. No kill-9 storm.
4. Play the **23.976 flash+beep** fixture (not another 20 s Farpoint restart):
   ```
   assets/avsync/trek_blip_720p23976.mp4
   ```
   scp to `/media/fat/misterplex/avsync/` and `--play-file` **or** PMS play after adding it to the library.
5. Capture HDMI A+V on **this** host:
   ```
   ffmpeg -y -f v4l2 -input_format mjpeg -video_size 1280x720 -i /dev/video0 \
     -f alsa -ac 2 -ar 48000 -i hw:CARD=MS2109,DEV=0 \
     -t 20 -c:v copy -c:a pcm_s16le /tmp/misterplex-avsync/hdmi-blip.mkv
   python3 scripts/measure_flash_beep.py /tmp/misterplex-avsync/hdmi-blip.mkv
   ```
6. Tune **code** so median offset is ~0 **with all delays at 0**. Leave `AUDIO_DELAY_MS` as the user knob.
7. Then replay Home PMS TNG Farpoint `rk=40868` offset 234000 and confirm dialogue by HDMI, not logs.

## Secrets

`Memory/lab/local/secrets.env` (gitignored). Example: `Memory/lab/local/secrets.example`.

## Bans

No Quartus unless a new RBF is required (it is not). No `deploy_plex_core.sh`. No docs mill. No 2 m scheduler refill.
