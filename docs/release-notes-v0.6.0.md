# MiSTerPlex v0.6.0

Current product line. Same 720p24 FPGA core as v0.5.0, new companion.

| Piece | Id |
|-------|-----|
| `cores/Plex.rbf` | md5 `03f1b95ac67a568f24193234ea8cb072` |
| HDMI | CEA 720p60 `1280,110,40,220,720,5,5,20,74250` (VGA follows when `vga_scaler=1`) |

## User-facing

- Display **240p / 480p / 720p** applies when the daemon starts (not live).
- Content resolution still changes immediately.
- Auto HDMI audio delay is per display mode. `AUDIO_DELAY_MS` stays the user knob.
- 23.976 titles pace at 24000/1001.
- Identity 720p play holds ~24 fps on HDMI.

VGA Display 240p uses a 25.175 MHz 640×480 modeline so typical VGA monitors lock.

## Install

Same layout as v0.5.0. Copy `cores/Plex.rbf` to `/media/fat/_Utility/Plex.rbf`
(or `/media/fat/Plex.rbf`). Set `PLEX_BASE` in `misterplex.conf`. Leave
`AV_HDMI_AUDIO_LAG_MS` unset or `0` for auto delay.

## Not a new bitstream

No Quartus fit in this release. The RBF is the already-named `03f1b95a` silicon.
