# HDMI_FIRST_720P60 — work HDMI before VGA / 15 kHz TV

**Living 2026-08-14T22:24Z — parent.** User: work the **HDMI side first**;
a later TV can do **15 kHz**. VGA CRT range is recorded but **not** the
apply target this tick.

## Recipe (HDMI now)

Stock Main drops preset `video_mode 0/5/6`. Custom only:

```
video_mode 1280,110,40,220,720,5,5,20,74250
```

CEA-861 **720p60** / **74.25 MHz** / **60.000 Hz** / H ≈ **45.0 kHz**.
**Not** 24 Hz HDMI. **P4-HZ** stays **DEFER**.

Live `/media/fat/MiSTer.ini` (backup
`/media/fat/MiSTer.ini.before-hdmi-720p60-20260814`):

| Section | Key |
|---------|-----|
| `[MiSTer]` | `video_mode=1280,110,40,220,720,5,5,20,74250` |
| `[Plex]` | same custom line |
| `vga_scaler` | **1** (VGA follows HDMI) |
| `vsync_adjust` | **0** |
| `direct_video` | **0** |

Also wrote `/dev/MiSTer_cmd` the same custom line (CMD1–CMD6). INI store
alone does not move PHY (`P4_RASTER_CMD_VS_INI.md`).

## Eyes (L58) — not PHY PASS

| File | md5 prefix | I SAW |
|------|------------|-------|
| `hdmi720-2219.jpg` | `e74e3559` | FALSE-BLACK first-frame |
| `hdmi720-2219-ss1.jpg` | `7feb0070` | MENU Bubble Bobble **full-bleed** (no bars). No OSD. |
| `hdmi720-2222-ss1.jpg` | `cb565cbb` | Same splash **letterboxed** in 16:9. No OSD. |
| `hdmi720-2225-ss1.jpg` | `d2589f22` | Smear / scaler hunt. No OSD. |

`dmesg` `MiSTer_fb` toggles **1280×720 ↔ 640×480** (OSD FB around
`video_info`, **not** a sticky analog-line readout).

**PHY_PASS=NO.** **HDMI_PASS=NO.** No overlay analog
`1280x720  74.25MHz  60.0Hz` this tick. WRITE_OK ≠ PHY PASS (**L55**).
USB JPEG 1280×720 ≠ PHY. unique24 leftover **12.5** F@118=**NO**
orthogonal. **FIT_GO=NO.**

CORE at apply = **MENU**. Disk Plex.rbf **`f02aa88b` SKIP_RESTORE**.
Did **not** load `_Utility/Plex.rbf`. Did **not** Quartus. Did **not**
`/bin/fpga`. Did **not** restore **`07f54d9f`**.

## CRT / 15 kHz (deferred)

VGA CRT user range: **Hf 28–70 kHz**, **Vf 40–120 Hz**.
720p60 analog/scaler = **45 kHz / 60 Hz** → **in range** with
`vga_scaler=1`. Native **15 kHz 240p** and analog **720p24**
(~18 kHz / 24 Hz) are **out** of this CRT. Later 15 kHz TV owns that.
Do **not** send 24 Hz HDMI to this CRT while `vga_scaler=1`.
