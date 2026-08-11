# MiSTerPlex

Cast Plex to your [MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/) — phone, desktop, or web.  
Your MiSTer plays the video; no PC in the middle.

## What you need

- MiSTer (DE10-Nano) on your network  
- Plex Media Server on the same network  
- HDMI or VGA, as usual  

The release tarball includes everything else (daemon, FPGA core, `ffmpeg`).

## Install

1. Download the [latest release](https://github.com/flynnsbit/MisterPlex/releases) and extract it.
2. Copy to the MiSTer (example with SSH; password is often `1`):

```bash
tar xzf misterplex-*.tar.gz && cd misterplex-*
ssh root@MISTER_IP "mkdir -p /media/fat/misterplex"
scp -r bin scripts licenses root@MISTER_IP:/media/fat/misterplex/
scp cores/Plex.rbf root@MISTER_IP:/media/fat/_Utility/
scp conf/misterplex.conf.example root@MISTER_IP:/media/fat/misterplex/misterplex.conf
```

3. Edit `/media/fat/misterplex/misterplex.conf` — set your server:

```ini
PLEX_BASE=http://YOUR-PLEX-SERVER:32400
```

Keep the other defaults from the example unless you know you need to change them.

4. On the MiSTer, start the daemon once (or add it to your user startup):

```bash
chmod +x /media/fat/misterplex/bin/*
nohup /media/fat/misterplex/bin/misterplexd \
  --conf /media/fat/misterplex/misterplex.conf \
  >/media/fat/misterplex/misterplexd.log 2>&1 &
```

5. OSD (**F12**) → load **Plex** from `_Utility`.  
6. In any Plex app: cast to **MiSTerPlex**.

## Controls (while playing)

| Key | Action |
|-----|--------|
| **Space** | Play / pause |
| **Esc** | Stop |
| **→** | Skip forward |
| **←** | Skip back |

Map a controller under F12 → **Define joystick buttons** (Play/Pause, Stop, Skip Fwd, Skip Back).  
Local actions show a short on-screen overlay (state, progress, skip).

## Check that it is running

```bash
curl http://MISTER_IP:3005/resources
```

You should get a short XML player description.

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| Not listed as cast target | Daemon not running, or port **3005** blocked. Run the `curl` check above. |
| Cast works, screen black | Load the **Plex** core from the OSD (daemon alone is not enough). |
| Starts then stops | Check `/media/fat/misterplex/misterplexd.log` — often missing `bin/ffmpeg`. |
| No sound | Plex core must be loaded; audio goes through the core. |
| OSD / core switching broken | Reboot MiSTer once (rare daemon crash could stick Main). |

## Releases

| Version | Best for |
|---------|----------|
| **v0.3.0** | Stable day-to-day use (playback controls + overlay, 320×240) |
| **v0.4.0** | Higher content sizes (480p / 720p ladder) — more advanced, still maturing |
| **v0.2.0** | Minimal first release |

Always install **matching** files from one tarball — do not mix cores and daemons from different versions.

## License

Project code is under the repository license. Bundled `ffmpeg` is **GPLv3**; see `licenses/ffmpeg/` in the tarball.
