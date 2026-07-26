# MiSTerPlex

**A native Plex client for [MiSTer FPGA](https://mister-devel.github.io/MkDocs_MiSTer/).**

Cast from any Plex app — phone, desktop, or web — and your MiSTer plays it. The FPGA owns
pixel and audio presentation the way a console core does; an ARM daemon (`misterplexd`) owns
the Plex protocol and networking.

This is not a PC cast app using the DE10-Nano as a dumb display. The product is a dedicated
`Plex.rbf` core plus an on-device daemon.

---

## Requirements

| | |
|---|---|
| **Hardware** | DE10-Nano running MiSTer, on your network |
| **Server** | Plex Media Server reachable from the MiSTer |
| **Display** | HDMI or VGA/CRT, as you normally use |

Everything else you need — the daemon, the FPGA core, and a static ARM `ffmpeg` — is in the
release tarball.

---

## Install

Download the latest release tarball from the
[Releases page](https://github.com/flynnsbit/MisterPlex/releases), then:

### 1. Copy files to the SD card

```bash
# from a machine that can reach the MiSTer over SSH (default user root, password 1)
tar xzf misterplex-*.tar.gz
cd stage-misterplex   # or the extracted directory

ssh root@<mister-ip> "mkdir -p /media/fat/misterplex"
scp -r bin scripts docs root@<mister-ip>:/media/fat/misterplex/
scp cores/Plex.rbf   root@<mister-ip>:/media/fat/_Utility/
scp conf/misterplex.conf.example root@<mister-ip>:/media/fat/misterplex/misterplex.conf
```

Resulting layout on the MiSTer:

```text
/media/fat/misterplex/bin/misterplexd    # the daemon
/media/fat/misterplex/bin/ffmpeg         # bundled static ARM FFmpeg
/media/fat/misterplex/misterplex.conf    # your settings
/media/fat/_Utility/Plex.rbf             # the FPGA core
```

### 2. Configure

Edit `/media/fat/misterplex/misterplex.conf` and set your server:

```ini
PLEX_BASE=http://192.168.1.10:32400
DECODE=320x240
PRESENT=fb0
```

`PLEX_BASE` is the only value most people need to change. A fully annotated reference lives in
[`assets/misterplex.conf.example`](assets/misterplex.conf.example).

### 3. Start on boot

Append to `/media/fat/linux/user-startup.sh` (create it if absent):

```sh
/media/fat/misterplex/bin/misterplexd \
  --conf /media/fat/misterplex/misterplex.conf \
  >>/media/fat/misterplex/misterplexd.log 2>&1 &
```

Then reboot, or start it by hand for a first try:

```bash
ssh root@<mister-ip>
chmod +x /media/fat/misterplex/bin/*
/media/fat/misterplex/bin/misterplexd --conf /media/fat/misterplex/misterplex.conf &
```

### 4. Load the core and cast

1. On the MiSTer, open the OSD (**F12**) and load **Plex** from `_Utility`.
2. Open any Plex app on the same network.
3. Pick a video, hit the cast button, and choose **MiSTerPlex**.

### Playback controls

MiSTerPlex can publish local keyboard/controller playback commands from the core to the
daemon. In builds that include the input-mailbox dispatcher, the controls are:

| Keyboard | Action |
|---|---|
| **Space** | Play / pause |
| **Esc** | Stop |
| **Right Arrow** | Skip forward |
| **Left Arrow** | Skip back |

For controllers, use MiSTer's normal mapping flow: open the OSD (**F12**) and choose
**Define joystick buttons**. The Plex core declares these button prompts, in this order:

1. **Play/Pause**
2. **Stop**
3. **Skip Fwd**
4. **Skip Back**

After you map them once, MiSTer applies that controller mapping to the core. Local commands
show an on-screen overlay with a state icon/label, elapsed and total time, and a progress bar.
Skip actions also flash a short `30S >>` or `<< 30S` confirmation. The overlay appears when a
command is handled, stays up briefly, then fades out automatically; while paused, the daemon
keeps refreshing the last video frame so the overlay can update and disappear cleanly.

The casting Plex app (phone, web, desktop) is kept in sync too: local playback actions are
reported back through the Companion timeline long-poll, normally within about **400 ms**.

### ffmpeg

`misterplexd` shells out to a static ARM `ffmpeg` for transcoding. **It is bundled in the
release** as `bin/ffmpeg`, so a stock install needs nothing extra.

The daemon probes, in order:

1. `/media/fat/misterplex/bin/ffmpeg` (the bundled one)
2. `/media/fat/mistercast/bin/ffmpeg` (if you also run
   [mistercast-linux](https://github.com/flynnsbit/mistercast-linux))

To use a different build, replace `bin/ffmpeg` or set `FFMPEG=` in the conf. Any statically
linked `armv7` build with HTTPS support works.

---

## Verify it works

```bash
curl http://<mister-ip>:3005/resources    # should return a <Player> element
tail -f /media/fat/misterplex/misterplexd.log
```

You can also drive playback without a Plex app:

```bash
export PLEX_TOKEN=<your-token>
./scripts/plex_browse.sh --player <mister-ip>:3005 --base http://192.168.1.10:32400 sections
./scripts/plex_browse.sh --player <mister-ip>:3005 --base http://192.168.1.10:32400 play <ratingKey>
./scripts/plex_menu.sh                    # interactive TUI; runs on the MiSTer too
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| MiSTerPlex not offered as a cast target | Daemon not running, or port 3005 unreachable. Check `curl http://<ip>:3005/resources`. |
| Cast connects, screen stays black | `Plex.rbf` not loaded — the daemon and the core are independent. Load the core from the OSD. |
| Playback starts then stops | Usually ffmpeg. Check the log for the spawn line; confirm the binary exists and is executable. |
| Video plays, no audio | Audio goes to `/dev/MrAudio` via the core; confirm the Plex core is loaded, not another core. |
| Lip-sync drift | Set OSD **Content FPS** to match the source (24 for film). See [docs/match-source-hz.md](docs/match-source-hz.md). |
| F12/OSD dead, core won't change | A crashed daemon could strand MiSTer's `Main` process. Reboot the MiSTer; the crash cause is fixed in current releases. |

---

## Configuration highlights

| Key | Meaning |
|---|---|
| `PLEX_BASE` | Server URL. Multiple servers via `PLEX_SERVERS=a,b` or repeated `PLEX_BASE=` lines. |
| `DECODE` | Decode/present size, default `320x240`; `480x360` is hardware-verified. |
| `PRESENT` | `fb0` (default, safe), `fpga`, or `both`. |
| `SUBTITLES` | `off`, `burn` (server-side), or `ffmpeg` (local files). |
| `AUTO_NEXT` | Play the next play-queue item at end of media. Default on. |
| `SKIP_FORWARD_MS` / `SKIP_BACK_MS` | Core input skip deltas; defaults are +30s / -10s. |
| `SOURCE_FPS` | `auto` uses server metadata to log a Content FPS hint. |

Full reference: [`assets/misterplex.conf.example`](assets/misterplex.conf.example) and
[docs/release.md](docs/release.md).

---

## Features

- Cast from any Plex client — play, pause, resume, stop, seek
- Scrubber with duration and seek range; step ±10 s; skip next/previous
- Auto-play the next episode from the play queue
- Multi-server support, with the cast-selected server winning
- On-device browse CLI and interactive menu
- Subtitle burn-in (server-side or local)
- OSD controls: Content FPS, test patterns, TV mode, audio tone
- 3:2 / 2:2 cadence handling so 24 fps film is correct on a 60 Hz display

---

## Building from source

```bash
git clone https://github.com/flynnsbit/MisterPlex.git
cd MisterPlex
make unit        # host unit tests
make arm-plexd   # cross-compile the ARM daemon
make package     # release tarball in dist/
```

The ARM build needs an `arm-none-linux-gnueabihf` (or `arm-linux-gnueabihf`) cross compiler on
`PATH`, or point `ARM_TOOLCHAIN_BIN` at one.

### FPGA core

`Plex.rbf` is built with Quartus 17.0.2 (the MiSTer standard):

```bash
export MISTER_DEV=$HOME/Projects/misterfpga-dev
make build-rbf
```

Built cores are not tracked in git; each release ships one as an asset.

### Deploying to a device during development

```bash
export MISTER_HOST=192.168.1.183      # your MiSTer
./scripts/deploy_misterplexd.sh       # build and push the daemon
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh   # push the RBF and reload the core
```

---

## Layout

```text
fpga/Plex_MiSTer/    Quartus project → Plex.rbf
arm/misterplexd/     on-device daemon (companion + media)
host/libmisterplex/  shared algorithms (cadence, A/V clock)
scripts/             deploy, packaging, browse/menu, diagnostics
tests/unit|hw/       host unit tests and hardware test scripts
docs/                architecture, release, CRT/LCD matrix, phase notes
```

Architecture and design notes: [docs/architecture.md](docs/architecture.md).

---

## Project status

Cast playback, audio, A/V sync, and the OSD work on hardware today. FPGA-side H.264 decode is
in progress; until it lands, decoding happens on the ARM side while the FPGA owns presentation.
Per-phase detail is in [docs/PHASE_BACKLOG.md](docs/PHASE_BACKLOG.md); the older development
README is kept at [docs/DEVNOTES_legacy_readme.md](docs/DEVNOTES_legacy_readme.md).

## License

- FPGA core and `sys/`: GPL-2.0-or-later (MiSTer framework)
- Host and ARM tools: MIT unless noted otherwise

### Bundled third-party software

Release tarballs include an unmodified static armhf build of **FFmpeg 7.0.2**
(by [John Van Sickle](https://johnvansickle.com/ffmpeg/)), configured with
`--enable-gpl --enable-version3` and therefore licensed under the **GPLv3**. The full licence
text, the exact build configuration, and pointers to the corresponding source ship in
`licenses/ffmpeg/` inside the tarball.

FFmpeg is invoked as a separate subprocess, so it is an aggregate — bundling it does not place
MiSTerPlex's own sources under the GPLv3.
