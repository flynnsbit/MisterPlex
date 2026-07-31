# OSD / playback chrome sharpness (w-osd-hires)

Status: **silicon-verified** on stop path (`7defbdf6` / md5 `db3d9367`); read-back gate
validated on a **real HDMI pair**.  
Related: `host/libmisterplex/playback_overlay.hpp`, `arm/misterplexd/media_player.cpp`,
`fpga/Plex_MiSTer/rtl/present_core.sv`, `tools/readback_overlay_text.py`,
`docs/display-resolution.md`.

## Mechanism (settled)

`present_core.sv` fetches only **even** store rows (`STORE_Y_SCALE=2.0` with
`FRAME_H=480`). Glyphs drawn at vertical scale=1 lose alternate rows → character
corruption (`8→0`, `6→C`). Fix: **bodyScale/iconScale ≥ 2** and **even y-origin snap**.

## Paths (quoted)

| Event | Code | Format |
|---|---|---|
| Stop / idle chrome | `paintIdle()` → `overlay_.renderRgb24` @ coded W×H → RGB→I420 → DDR | RGB intermediate |
| Playback present | `renderOverlay` → `case Yuv420p: overlay_.renderYuv420p(...)` | direct YUV |
| Pause | `pause()` → `showPlaybackOverlay(Paused)` → **`publishPausedOverlayFrame()`** before `SIGSTOP` | YUV latch + `renderYuv420p` |

Pause/play paint is **in tree** (`media_player.cpp` `publishPausedOverlayFrame`,
`renderOverlay` Yuv420p branch). Parent stop-path capture proves stop; **pause/play
on silicon is still parent-only** — agent has not device-tested those two.

## Acceptance — string read-back (two-sided)

Gate specification fixtures (same device + grabber; differ only by the fix):

| Fixture | Expect |
|---|---|
| `tests/unit/fixtures/overlay_readback/overlay_lowres_evidence.png` | **RED** — must NOT recover `STOPPED` |
| `tests/unit/fixtures/overlay_readback/overlay_FIXED_db3d9367_stopped.png` | **GREEN** — must recover `STOPPED` |

```bash
python3 tools/readback_overlay_text.py --selftest-pair; echo "true rc=$?"
python3 tools/readback_overlay_text.py --image CAPTURE.png --expect STOPPED; echo "true rc=$?"
```

- Templates = shipped **8×13 / 12×16 @ scale≥2** (not legacy 5×7@1).
- HDMI 1080p is area-downsampled to a 640×480 content proxy before match.
- Unsupported geometry → `verdict=UNSCORED` **rc=77** (never collapsed into FAIL).
- Synthetic green alone is **not** the gate; the pair is.

## Multi-resolution output (parent switch procedure)

Output mode is **MiSTer.ini `[Plex]`**, not misterplex.conf. See
`docs/display-resolution.md`.

```sh
# on device (parent only)
cp /media/fat/MiSTer.ini /media/fat/MiSTer.ini.before-osd-hires-sweep
vi /media/fat/MiSTer.ini   # set video_mode / _ntsc / _pal in [Plex]
# recommended tiers:
#   video_mode=8  → 1920×1080@60  (already GREEN on FIXED capture)
#   video_mode=5  → 800×600@60
#   video_mode=6  → 640×480@60
# 240p-class: use a 240p modeline the lab already trusts, or vscale path that
# yields ~240 active lines — confirm with grabber actual WxH before scoring.
reboot
# after core up: cast → stop → capture HDMI → readback
python3 tools/readback_overlay_text.py --image CAP.png --expect STOPPED; echo "true rc=$?"
```

### Pre-registered predictions (publish hits/misses)

Chrome is authored on the **coded canvas** (product 624×480), not HDMI pixels.
ascal scales DE ~529×240 → whatever `video_mode` is. Odd-row cull is **unchanged**
across output modes (it is in `present_core` before ascal).

| Output (`video_mode`) | Signal | Prediction for STOPPED read-back | Notes |
|---|---|---|---|
| 8 — 1080p60 | 1920×1080 | **PASS** (measured GREEN on FIXED) | baseline |
| 5 — 800×600 | 800×600 | **PASS** | same content glyphs; more ascal shrink; separation still high enough |
| 6 — 640×480 | 640×480 | **PASS** | near 1:1 with presented bank; should be easiest after 1080p |
| 240p-class | ~320×240 / 640×240 | **PASS or tight** | layout picks 8×13 @ scale≥2; if grabber geometry is exotic → **UNSCORED 77**, not FAIL |
| Pause overlay | any | **PASS** (code path present; **untested on silicon**) | `publishPausedOverlayFrame` |
| Play overlay while playing | any | **PASS** when overlay visible (3s) (code path present; **untested on silicon**) | `renderYuv420p` each dirty present |

Miss condition to publish: any tier where human can read STOPPED but tool returns
FAIL, or tool PASS on unreadable mush.

## Out of scope

`V_STORE` / Quartus. Only if multi-res read-back stays RED on silicon with
human-legible chrome.
