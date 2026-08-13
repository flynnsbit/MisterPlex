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
2. Copy to the MiSTer (example with SSH):

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
nohup /media/fat/misterplex/bin/misterplexd_supervise.sh \
  >/media/fat/misterplex/misterplexd_supervise.log 2>&1 &
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

## Content quality modes

Open MiSTer's OSD with **F12**, then choose **Content resolution**. Keep
**Display resolution** on **Follow content** unless you want a custom MiSTer
scaler policy.

| Mode | User-facing function | Status |
|------|----------------------|--------|
| **240p** | 320×240 compatibility/performance mode. Best choice for older displays, low decode load, and maximum playback margin. MiSTer's scaler still controls the final HDMI/VGA aspect and output size. | **Production** |
| **480p** | Recommended quality mode. Presents true 640×480 with a 624×480 coded, 618×480 visible picture and centered pillars. The source aspect ratio is passed through so MiSTer's scaler can handle widescreen, 4:3, or custom display ratios. | **Production** |
| **720p** | Experimental 1280×720 content path for development and visual testing. The current dual-A9 decode path can miss realtime frame rate and let audio drift behind. | **Alpha** — not recommended for normal viewing |

240p and 480p are two settings in the same core; they do not require separate
RBF files. Changing the content mode during playback re-resolves the Plex
transcode and resumes near the same position.

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
| Plex Web plays but elapsed time stays at `0:00` | If the browser runs on the PMS host, reopen Plex at `http://127.0.0.1:32400/web`, reselect **MiSTerPlex**, and play again. See the origin note below. |
| OSD / core switching broken | Reboot MiSTer once (rare daemon crash could stick Main). |

### Plex Web timer stays at `0:00`

Plex Web can load from a server's LAN address while PMS's Companion proxy polls
the same server through `127.0.0.1`. Video still plays and the poll XML contains
advancing `time=`, but the two URLs are different browser origins. Some PMS
versions expose only `Location, Date` on the proxied response, so Plex Web cannot
read `X-Plex-Client-Identifier` and silently rejects the progress update.

Use one PMS origin consistently:

- Browser running on the PMS/Docker host: use
  `http://127.0.0.1:32400/web`.
- Browser running on another machine: use the PMS LAN URL that the server
  advertises; do not use `127.0.0.1`, which would point at that other machine.

For a permanent Docker fix that supports **both** URLs while preserving the
host-network GDM discovery used to list **MiSTerPlex**, use the supplied
[`plex-cors-proxy`](examples/plex-cors-proxy/) sidecar:

```bash
cp -a examples/plex-cors-proxy /path/to/your/plex-compose/
cd /path/to/your/plex-compose
PMS_LAN_IP=YOUR_PLEX_SERVER_IP docker compose \
  -f docker-compose.yml \
  -f plex-cors-proxy/docker-compose.override.yml \
  up -d --build
```

The sidecar leaves PMS in `network_mode: host`, proxies only HTTP port 32400,
and exposes `X-Plex-Client-Identifier` to Plex Web. It needs Docker
`NET_ADMIN` so it can install three narrowly scoped, self-removing NAT rules.
Stop it normally with `docker compose stop plex-cors-proxy`; its shutdown trap
removes those rules. Hard-refresh Plex Web and reselect **MiSTerPlex** after
starting or stopping it.

## Releases

| Version | Best for |
|---------|----------|
| **v0.4.1** | Recommended current release: production 240p/480p, true480 native aspect, timeline fix; 720p remains alpha |
| **v0.3.0** | Stable day-to-day use (playback controls + overlay, 320×240) |
| **v0.4.0** | Previous multi-resolution release |
| **v0.2.0** | Minimal first release |

The published v0.4.1 package uses the immutable
`release_artifacts/v0.4.1/Plex.rbf` artifact, MD5
`07f54d9f8f0eda2fe75d9cc314f6de54`. This merge does not rebuild or
reattribute that frozen RBF.

Always install **matching** files from one tarball — do not mix cores and daemons from different versions.

## License

Project code is under the repository license. Bundled `ffmpeg` is **GPLv3**; see `licenses/ffmpeg/` in the tarball.
