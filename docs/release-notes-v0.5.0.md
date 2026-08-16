# MiSTerPlex v0.5.0 — 720p24 product

First 720p@24 product line on the same MiSTerPlex companion. Live lab silicon:
RBF `03f1b95a` (freddo L4, V_TOTAL 750) + daemon `f763f5d1`.

This does **not** replace v0.4.1 true480. Keep `07f54d9f` for 240p/480p-native
glass. This tarball’s `cores/Plex.rbf` is the **720p24** bitstream.

## What’s in the box

| Piece | Id | Notes |
|-------|-----|--------|
| `cores/Plex.rbf` | md5 `03f1b95ac67a568f24193234ea8cb072` | 1280×720 L4, pix 23.684210 MHz → 24.07 Hz |
| `bin/misterplexd` | md5 `b8d6545b441c6b75e5fbb0210341950c` | inproc libav, 3-bank I420, HDMI audio gate |
| HDMI raster | `1280,110,40,220,720,5,5,20,74250` | ascal 60; VGA via `vga_scaler=1` |

## Validated on HDMI (MS2109 `/dev/video4`)

Black flash+beep fixtures (not BBB), play-file, `DECODE=1280x720`.

| Content | Path | Frames | pfps / hw_fps | Unique 24 | Glass |
|---------|------|--------|---------------|-----------|-------|
| 720p24 | inproc identity | 557/557 | 24.0 / 24.06 | **PASS** | BLIP720, clean |
| 480p24 | inproc nearest → 1280 | 531/531 | 22.0 / 22.05 | no (720p glass scale) | BLIP480, clean |
| 240p24 | inproc 4×3 → 1280 | 533/533 | 22.2 / 22.20 | no (720p glass scale) | BLIP240, clean |

No freeze, no black, no `bank out of range`. 240/480 no longer abort when the
file is not 1280×720.

### Lipsync (HDMI capture)

720p native hold is `AV_HDMI_AUDIO_LAG_MS=100` after first video kick.
Cropped 16 s window medians about **−12 / +25 / +31 ms**. The official
±42 ms harness still **FAIL**s on a 51 ms adjacent step (60 Hz capture of a
2-frame flash) and on the 4 s black lead-in starving the start window. That is
the same class as the earlier dedicated-blip +4 ms set — not the old +249 ms
late-audio bug.

480p middle ~0 to +16 ms. 240p reads late (~+70 ms) because that path runs
at 22 fps against realtime audio.

## Install

Same layout as v0.4.1. Copy `cores/Plex.rbf` to `/media/fat/Plex.rbf` (or
`_Utility` if you want it in the OSD list). Do **not** overwrite a working
true480 `07f54d9f` unless you intend to switch the box to 720p24.

```
DECODE=1280x720
DISPLAY_RES=720p
CONTENT_RES=720p
PRESENT=fpga
AV_HDMI_AUDIO_LAG_MS=100
AUDIO_CLOCK_PPM=-638
```

`MPX_INPROC_DECODE=1` for the lab play-file path.

## Not in this release

- Official HDMI harness status PASS at all three resolutions
- Unique-24 for 240p/480p files while the glass is forced 1280×720
- A new Quartus fit (this is the already-named `03f1b95a` silicon)
