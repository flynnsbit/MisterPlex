# A/V sync blip tests

Short clips with a **white flash** and a **1 kHz beep** every 1.0 s (aligned).

| File | Content fps | Duration |
|------|-------------|----------|
| `sync_24fps_blip.mp4` | 24 | 30 s |
| `sync_30fps_blip.mp4` | 30 | 30 s |

- **Visual:** full-frame brightness pulse for 2 frames at each integer second.
- **Audio:** loud 50 ms tone at the same times (otherwise quiet hum).
- **On-screen:** frame counter + fps label.

## On MiSTer lab

Copied to `/media/fat/misterplex/avsync/`.

Play via companion cast of a local path (if supported) or copy into a Plex library
and cast from PMS.

## What “good” looks like

On the display + speakers (or HDMI capture + waveform):

1. Flash and beep are **simultaneous** (within ~1 frame at 24 fps ≈ 42 ms).
2. Logs: `vfps ≈ content fps`, `pfps ≈ vfps` (no present drop), `audio_s ≈ wall_s`.

## Measuring lip-sync from HDMI

Capture HDMI with a card, then e.g.:

```bash
ffmpeg -i capture.mkv -vf "select='gt(scene,0.3)',showinfo" -af "silencedetect=n=-30dB:d=0.02" -f null -
```

Compare flash PTS vs beep onset.
