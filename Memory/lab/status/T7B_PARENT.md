# T7b parent (2026-08-13 ~23:12Z)

Companion **6f1afebe** deployed. Named j loaded (not overwrite of `Plex.rbf`).
Sidecar `/tmp/t7-l4.conf` + `--decode 1280x720`. Then restored **07f54d9f**.

| | |
|--|--|
| PLAY_RC | **0** |
| PLXJ | **ACK matched 16:9** (was timeout) |
| fabric | **plxp** `copy_us=0` |
| frames/presented | **212 / 212** `drops=0` |
| pfps | **14.1** hw_fps **14.10** |
| gate ≥23.9 | **FAIL** |
| historical e | 15.47 |
| audio | off (`audio_s=0`) |
| HDMI after | 1280×720@24 request / 640×480@59.9 PHY |

Display `video_mode 5` **wrote**; HDMI PHY **still 640×480@59.9**. P4-DISPLAY TODO.

False **glass=L4** on true480: leftover PLXJ magic at `0x3047F130`.
