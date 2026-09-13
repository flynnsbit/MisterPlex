# MisterPlex modes (pair = RBF + conf; one unified daemon)

**You do not pick daemons by hand.** Use the Scripts TUI or CLI:

- **Scripts → `MiSTerPlex_Mode`** (on-box TUI)
- CLI: `/media/fat/misterplex/bin/switch_misterplex_mode.sh 240p|480i|480p|status`

The switcher stops any `misterplexd`, installs the mode conf, copies the matching RBF to `Plex.rbf`, starts the **unified** companion, and reloads Menu→Plex when `/dev/MiSTer_cmd` is available.

| Mode | RBF | md5 prefix | Conf | Backend | Glass |
|------|-----|------------|------|---------|-------|
| **240p** | `Plex_240p_AU32.rbf` | `4ce24aa9` | `profiles/misterplex.conf.240p` | fpga-h264 | YES |
| **480i** (product) | `Plex_480i_host_audio.rbf` | `56f38fff` | `profiles/misterplex.conf.480i` | legacy host-paint | YES + lipsync |
| **480p** (host) | `Plex_480p_host.rbf` | `9014f49e` | `profiles/misterplex.conf.480p_host` | legacy host-paint | YES + lipsync (lab HDMI) |

Unified daemon: `bin/misterplexd.unified` (**f3035176** queue-cap). Same binary; conf selects path.

`IDLE_SCREEN=logo` on all product profiles (`off`/`last` = sticky last frame — do not use).

480p profile: `AUDIO_DELAY_MS=80`. 480i profile: `AUDIO_DELAY_MS=100`.

Tokens/PLEX_BASE are preserved across switches via `misterplex.conf.tokenbak`.
