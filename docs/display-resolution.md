# Display output resolution

MiSTerPlex has two separate resolutions:

- **Output resolution** — the HDMI/VGA signal MiSTer sends to your display. This is controlled by
  MiSTer's scaler (`ascal`) and `/media/fat/MiSTer.ini`.
- **Content/native resolution** — the picture MiSTerPlex decodes and presents internally. Today that
  remains **320×240** by default.

Raising the output mode gives a higher-resolution **signal**, not a higher-resolution decoded picture.
For example, `video_mode=8` gives a 1920×1080@60 HDMI signal, but the current MiSTerPlex content path is
still a 320×240 picture scaled up by MiSTer.

## Change the MiSTerPlex output mode

Output mode is **not** a `misterplex.conf` setting. Edit the `[Plex]` section of
`/media/fat/MiSTer.ini`, then soft-reboot MiSTer so the core reloads with the new mode.

1. Back up the ini:

   ```sh
   ssh root@<mister-ip>
   cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.before-misterplex-video
   ```

2. Edit only the `[Plex]` section:

   ```sh
   vi /media/fat/MiSTer.ini
   ```

   Example: 1920×1080@60 HDMI output:

   ```ini
   [Plex]
   video_mode=8
   video_mode_ntsc=8
   video_mode_pal=8
   vsync_adjust=0
   refresh_min=0
   refresh_max=0
   direct_video=0
   vscale_mode=0
   vga_scaler=1
   ```

   Example: return to the VGA/LCD-safe default, 800×600@60:

   ```ini
   [Plex]
   video_mode=5
   video_mode_ntsc=5
   video_mode_pal=5
   vsync_adjust=0
   refresh_min=0
   refresh_max=0
   direct_video=0
   vscale_mode=0
   vga_scaler=1
   ```

   Before rebooting, verify the anti-retune pins are still active:

   ```sh
   python3 scripts/check_mister_ini_plex_guard.py path/to/MiSTer.ini
   ```

   The reference keys live in `assets/MiSTer.ini.Plex.required`, and `make unit`
   exercises the checker against good and intentionally broken examples. Do not
   comment out `video_mode`, `video_mode_ntsc`, or `video_mode_pal` in `[Plex]`
   unless you are deliberately changing the reference with lab evidence.

3. Reboot:

   ```sh
   reboot
   ```

## Recommended modes

These recommendations come from the 2026-07-26 output-mode sweep in
[`crt-lcd-matrix.md`](crt-lcd-matrix.md). The test held each mode for 120 seconds with existing
320×240 content. HDMI sync locked for every recommended mode below, drops stayed in the same range as
baseline, A/V drift stayed in the same band, and CPU remained **0% idle** in every row.

| `video_mode` | Output signal | Recommendation | Sweep evidence |
|---:|---|---|---|
| 5 | 800×600@60 | **Default**; safest LCD/VGA choice | HDMI PASS; VGA baseline envelope; drops 0; drift −32…−21 ms; 0% idle |
| 6 | 640×480@60 | Conservative VGA fallback | HDMI PASS; within VGA envelope; retest drops 2; drift −40…−20 ms; 0% idle |
| 1 | 1024×768@60 | Supported HDMI mode | HDMI PASS; drops 1; drift −40…−20 ms; 0% idle |
| 0 | 1280×720@60 | Supported HDMI 720p60 | HDMI PASS; drops 0; drift −40…−20 ms; 0% idle |
| 7 | 1280×720@50 | Supported HDMI 720p50 | HDMI PASS; drops 0; drift −35…−24 ms; 0% idle |
| 8 | 1920×1080@60 | Supported HDMI 1080p60 | HDMI PASS; drops 0; drift −38…−25 ms; 0% idle |
| 9 | 1920×1080@50 | Supported HDMI 1080p50 | HDMI PASS; drops 1; drift −40…−20 ms; 0% idle |
| 4 | 1280×1024@60 | **Not recommended / inconclusive** | Playback was OK, but HDMI capture failed to relock on retest |

Modes 12 (1920×1440@60) and 13 (2048×1536@60) also passed the lab sweep, but they are above the
1080p user-facing target and are not default recommendations.

## VGA guidance

The lab VGA panel is rated only to **800×600@60**. With `vga_scaler=1`, VGA follows the same scaler
mode as HDMI. If you use VGA, stay at:

- `video_mode=5` for 800×600@60, or
- `video_mode=6` for 640×480@60 fallback.

Higher HDMI modes can work well over HDMI, but they also push VGA to that same higher mode. If your VGA
display cannot sync above 800×600@60, choosing a high HDMI mode may make the VGA output unusable.

## Native/content resolution selector

The Plex core now exposes a runtime OSD selector for the **native content resolution**:

```text
F12 → Content resolution → 320x240 or 640x480
```

This is deliberately separate from `video_mode`. For example:

- `video_mode=8` + `Content resolution=320x240` = a 1080p output signal carrying the proven
  320×240 content path scaled by MiSTer.
- `video_mode=8` + `Content resolution=640x480` = a 1080p output signal carrying a 640×480
  native frame, once the 480p pipeline pieces are present.

The selector is one core, not a separate "480p build". `320x240` is still the default so existing
installs keep the proven path. The ARM daemon reads the same OSD status word (`O[4]`) that the RTL
uses, via the DDR OSD mailbox, before starting playback. That keeps Plex server resolution,
ARM decode size, and the core's native-resolution selector tied to one source of truth instead of
separate ARM/RTL copies.

### 480p status

Choose `640x480` only for 480p test builds that include all three required pieces:

1. DDR-backed frame store in the core, so the frame buffer is not limited to the old BRAM-sized
   320×240 path.
2. ARM RGB565 conversion and DDR frame writes sized for 640×480.
3. Plex weak-ladder resolve requesting a 640×480 stream.

Current claim level: **fits and closes timing / within modelled bandwidth**. The 480p path is not
hardware-validated yet, so do not describe it as supported until a lab run proves playback on
silicon. The output-mode sweep above remains valid: output signal resolution is effectively free;
native 480p content is the part that needs validation.

## What this does and does not mean

The sweep shows that **output resolution is effectively free** for the current path: MiSTer's scaler does
the output enlargement in HPS DDR3, so moving HDMI from 800×600 to 1080p did not measurably cost ARM CPU
or A/V lock.

It does **not** mean MiSTerPlex decodes native 1080p content today. Native/content resolution is still
limited by:

- the current frame-store path, which is moving from BRAM to SDRAM under ongoing work, and
- the ARM decode/transcode path, which was already at **0% idle** even with 320×240 content.

So: 1080p output signal is supported today; 1080p native picture quality is future work.
