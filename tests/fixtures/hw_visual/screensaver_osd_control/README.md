# Screensaver / `OSD_CONTROL` evidence — RBF `fb4bad84`, 2026-07-28

Real HDMI captures from `/dev/video0` (MJPEG 1280x720) of the MiSTer at
192.168.1.183, core `Plex`, `PRESENT=fpga DECODE=624x480`. In **both** sets the
core's OSD word had `status[15:14] = 10` — "Idle screen = Screensaver". The only
difference between them is the `OSD_CONTROL` line in
`/media/fat/misterplex/misterplex.conf`.

| Set | `OSD_CONTROL` | Daemon log | `scripts/idle_motion_probe.py` |
|-----|---------------|------------|-------------------------------|
| `red_osd_control_0/` | `0` | only `idle screen painted (mode=0)` | `STATIC`, travel **0.0 px** |
| `green_osd_control_1/` | `1` | `OSD word=0x8000 … idle=2` then `idle screen painted (mode=2)` | `MOVING`, travel **518.2 px** |

With `OSD_CONTROL=0`, `MediaPlayer::startOsdPoll()` returns before starting its
thread, so the OSD word is never read. The user's menu selection is discarded in
silence — no error is logged and nothing on screen changes. That is the whole of
"the screensaver still dont work".

Two traps these frames document:

* Every frame in `red_osd_control_0/` differs from its neighbours by about 17% of
  the left region, because the resident core re-damages a ragged prefix of every
  scanline each frame. A screensaver gate written as "do consecutive frames
  differ?" passes on this completely static picture. The centroid metric in
  `idle_motion_probe.py` reads it as travel 0.0 px, which is correct.
* `scripts/hdmi_capture_classify.py` grades `green_osd_control_1/` as
  `VALID_BLACK`, because a moving logo on black has a low mean. The screensaver
  is working in those frames. `VALID_BLACK` from that classifier means "dark",
  not "nothing is drawn".

Also measured in the same session, on the `OSD_CONTROL=1` restart: the daemon
read a persisted OSD word of `0x6000` (idle bits `01` = Black) and logged
`idle=1 (idle unchanged)`, then painted **mode=0** — the Plex logo. The
saved-word-forces-black defect recorded in `docs/PHASE_BACKLOG.md` is fixed by
`shouldApplyOsdIdle()`, which treats the first word seen as a baseline.
