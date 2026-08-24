# Daemon vs RBF load order

**Rule:** Pattern=None Plex scanout is black until `misterplexd` paints + doorbells.
The presenter must be live the instant `CORENAME=Plex`. Soft-stop *during* `load_core`
only (mid-SPI + FPGA reload lockups). Do not SPI into Menu. Copy-only must not kill
the daemon.

`scripts/deploy_plex_core.sh`: kill companion only when `DEPLOY_LOAD=menu|core`;
after Plex enumerates, start supervise/daemon (`DEPLOY_START_DAEMON=1` default).

# slot720p24j HDMI

- RBF md5 `968b828a8ec572bccf43b7bc2d31625a` BUILD_OK TIMING_OK DEPLOY_OK
- After paint: `ORANGE_PX=11947` ACTIVE `1280x719` capture `/tmp/plex-hdmi-eyes/j.png`
- Eyes: orange chevron + OSD. OSD still reports analog/HDMI `640x480 25.18MHz 59.9Hz`
  under a `1280x720 / 24.0Hz` request — **P4-DISPLAY still open**. Not unique-24 PASS.
