# PARENT LIPSYNC RUN CARD

## GATING ANSWER — AUDIO PATH EXISTS

Host enumeration (this session, direct rc):

```
$ arecord -l ; echo "true rc=$?"
**** List of CAPTURE Hardware Devices ****
card 0: MS2109 [MS2109], device 0: USB Audio [USB Audio]
  Subdevices: 1/1
true rc=0

$ cat /proc/asound/cards
 0 [MS2109         ]: USB-Audio - MS2109
                      MacroSilicon MS2109 at usb-0000:00:14.0-3.1, high speed

$ v4l2-ctl --list-devices
UVC Camera (534d:2109): ... /dev/video0   # SAME USB bus as MS2109 audio

$ arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 1 …/alsa_probe.wav
true rc=0
-rw-r--r-- 192044 bytes   # = 48000*2*2*1 + 44 header
```

**Hard positive: HDMI grabber carries audio on ALSA `hw:0,0`.**  
Video = `/dev/video0`. One ffmpeg, shared wallclock. Not av_drift_ms.

## NOT in scope
- Frame loss / cadence judder (parent settled; w-geom owns RTL)
- `av_drift_ms` (servo deadband — `av_clock.hpp` + `av_drift_role=servo_error_not_lipsync`)

## Fixture needs for w-asset480 (relay)
Period **1.0 s** · full-frame white flash **≥2 frames @24.000** · **1 kHz 50 ms** beep file-aligned · duration ≥30 s (prefer ≥180) · fps **24/1 only**.  
Detail: `.agent-work/w-avsync/FIXTURE_SPEC_FOR_W_ASSET480.md`

## Pre-registered (score after run)
| ID | Prediction |
|----|------------|
| P1 | SCORE \|offset_ms\| < 80 raw @ LEAD=40 |
| P2 | n_flashes≥15 n_beeps≥15 on 30 s play |
| P3 | no DISPLAY_FLAT |
| P4 | artifact_pair = rbf_md5+daemon_md5 both measured |
| P5 | decode_src stamped (do not pool across values) |

## Paste command

```bash
cd /home/flynnsbit/Projects/MisterPlex
fuser -v /dev/video0 || true          # must be free; busy ≠ zero
arecord -l | head -6
# cast flash+beep blip (30 s asset OK)
OUT=$PWD/avsync_hdmi_out/lipsync_$(date +%Y%m%dT%H%M%S)
DURATION=30 TOL_MS=42 MIN_PAIRS=15 DECODE_SRC=caller_supplied OUT="$OUT" \
  bash tools/avsync_lipsync_soak.sh >"$OUT/soak_wrap.txt" 2>&1
echo "soak true rc=$?"
grep -E '^(SCORE |VERDICT=|no_flash_class=|artifact_pair=|rbf_md5=|n_flashes=)' \
  "$OUT/soak_wrap.txt" "$OUT/lipsync_stdout.txt" 2>/dev/null
```

Long: `DURATION=60 MIN_PAIRS=40`.  
Artifacts: `$OUT/artifacts.json` + SCORE line includes `rbf_md5` `daemon_md5` `artifact_pair` `decode_src`.

## Sign / tags
`offset_ms=(t_beep−t_flash)×1000` · **+ = audio LATE** · every value tagged measured|caller_supplied|DEFAULT_ASSUMED · empty = NO-DATA never 0.

## Host green
self rc=0 · unit 29/29 rc=0 · adelay100 → offset 99 rc=2 · VIDEO_BUSY is distinct error
