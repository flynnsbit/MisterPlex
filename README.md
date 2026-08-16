# MiSTerPlex

Cast Plex to a [MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/). The FPGA
plays the video. No PC in the middle.

## Target

- **MiSTer FPGA** (DE10-Nano)
- HDMI or VGA (VGA needs a monitor that accepts 640×480 @ 25.175 MHz)
- A Plex Media Server on the same LAN
- Phone, desktop, or Plex Web as the remote

The release tarball includes the Plex core (`Plex.rbf`), the ARM companion
(`misterplexd`), and `ffmpeg`.

## Features

- Cast from any Plex app to **MiSTerPlex**
- Content **240p / 480p / 720p** (OSD, applies immediately)
- Display **240p / 480p / 720p** (OSD, applies when the daemon starts)
- Auto audio delay per display mode; `AUDIO_DELAY_MS` if you want to nudge it
- Play, pause, seek, and skip from the Plex app or the OSD
- 23.976 film titles stay on film time (not rounded to 24)

## Install

1. Download the [latest release](https://github.com/flynnsbit/MisterPlex/releases)
   and extract it.
2. Copy onto the MiSTer (password is often `1`):

```bash
tar xzf misterplex-*.tar.gz && cd misterplex-*
ssh root@MISTER_IP "mkdir -p /media/fat/misterplex /media/fat/_Utility"
scp -r bin scripts licenses root@MISTER_IP:/media/fat/misterplex/
scp cores/Plex.rbf root@MISTER_IP:/media/fat/_Utility/
scp conf/misterplex.conf.example root@MISTER_IP:/media/fat/misterplex/misterplex.conf
```

3. Set your server in `/media/fat/misterplex/misterplex.conf`:

```ini
PLEX_BASE=http://YOUR-PLEX-SERVER:32400
```

Leave the rest unless you know you need it. `AUDIO_DELAY_MS=0` is the default;
raise it if voice is early.

4. Start the daemon (or add this to `/media/fat/linux/_user-startup.sh`):

```bash
chmod +x /media/fat/misterplex/bin/*
nohup /media/fat/misterplex/bin/misterplex_core_watch.sh \
  >>/media/fat/misterplex/misterplex_core_watch.log 2>&1 &
```

5. OSD (**F12**) → **_Utility** → **Plex**.
6. In any Plex app, cast to **MiSTerPlex**.

`curl http://MISTER_IP:3005/resources` should return a short XML player card.

### Controls

| Key | Action |
|-----|--------|
| Space | Play / pause |
| Esc | Stop |
| → | Skip forward |
| ← | Skip back |

Map a controller under F12 → **Define joystick buttons**.

Display resolution is chosen in the OSD and applied the next time the daemon
starts. Content resolution changes on the next play (or live, if you already
have a session).

## Build your own

You only need this if you are changing the daemon or the FPGA. A released
tarball is enough to run MiSTerPlex.

**Daemon (ARM):** an `arm-none-linux-gnueabihf-g++` (or `arm-linux-gnueabihf-g++`)
and, for in-process H.264, a static ARM libav.

```bash
make arm-plexd
VERSION=v0.6.0 make package
```

`make package` rebuilds the ARM binary and wraps it with the verified `Plex.rbf`
plus `ffmpeg`.

**FPGA:** Quartus 17.0.2 via `scripts/build_rbf.sh`. One fit at a time. Not
required to run a released tarball.

## License

Project code uses the repository license. Bundled `ffmpeg` is GPLv3 — see
`licenses/ffmpeg/` in the tarball.
