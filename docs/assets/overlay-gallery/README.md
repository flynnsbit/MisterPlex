# Host overlay gallery — grabber-independent review

**NOT device verification.** Every PNG is a host CPU composite of the same
APIs the daemon uses (`renderIdleRgb24` + `PlaybackOverlay::renderRgb24`).
There is **no** `present_core`, **no** ascal, **no** DDR latch, **no** HDMI.

Regenerate:

```bash
cd /path/to/w-osd-hires
make "$PWD/build/dump_overlay_png"
OUT=.agent-work/w-osd-hires/gallery
./build/dump_overlay_png "$OUT/01_BEFORE_bank_paused_12x16.png" --scenario paused --before-12x16
./build/dump_overlay_png "$OUT/02_AFTER_bank_paused_24x32.png" --scenario paused --path bank
# … see tools/dump_overlay_png.cpp --help
# Capture: cmd; echo "true rc=$?"
```

## What the overlay knows about “native res” (quoted)

| Fact | Source |
|------|--------|
| Authoring pixels | Always bank `CODED 624×480` when `plane=0` — `ddr_frame_layout_params.svh:5-10`, host twin `ddr_frame_layout.hpp` |
| `output=` log field | `overlayOutputGeomTag()` reads **MiSTer.ini `video_mode` only** (`media_player.cpp:59+`, `mister_video_mode.hpp`). Labels intent. Does **not** change authoring canvas. |
| `source=none` / `DEFAULT_ASSUMED` | Ini missing or unreadable on host; authoring still 624×480 |
| `plane=0` | `chromePlaneLive() = chromePlaneConf_ && chromePlaneHw_` both default false (`media_player.hpp:72-73,349-350`). `setChromePlaneHwPresent` never set true; `plex_chrome.sv` **not** in `files.qip` |

**Conclusion (correct negative):** host/daemon cannot draw true HDMI-native chrome without a new RBF (post-ascal plane or larger store). Ini mode only annotates logs.

## Files

| File | Meaning |
|------|---------|
| `01_BEFORE_*_12x16` | Pre-hires **proxy**: bank size + output-layout metrics → font 12×16@2 |
| `02_AFTER_*_24x32` | **Product tip** path: bank plane=0 → font 24×32 cell 48×64 |
| `03/04_*_long*` | Long title + ellipsis + elapsed clamp (`pos=52000` `dur=30016` → both times `0:30`) |
| `05_*_idle_logo` | Idle logo only (`IdleMode::Logo` — matches `IDLE_SCREEN=logo`; **do not change product default**) |
| `06_*_NNto_*_SIMULATED` | AFTER bank nearest-neighbor scaled to mode sizes. **Label = SIMULATED stretch, not ascal** |
| `07_HYPOTHETICAL_plane1_*` | `setOutputRasterLayout(true)` at HDMI sizes. **Not shipping** (`plane=0` on device) |

## Before → after (what to look for)

- **BEFORE** 12×16: smaller glyphs, title often one line.
- **AFTER** 24×32: larger glyphs, `MISTERPLEX` on second line when needed; long title shows real `.` ellipsis (`MISTERP...` not blank-dot `MISTERP`).
- Elapsed/total both `0:30` when `pos≥dur` (unifies with progress bar).

## Host render does NOT cover

1. DDR push / bank latch  
2. `present_core` even-row cull + 640×480 present stretch  
3. ascal polyphase to HDMI  
4. Live `chromePlaneHw_` / plane=1  
5. Grabber / glass pixel vindication  

Device glass still requires parent redeploy of tip daemon when grabber is healthy (`tools/grabber_preflight.py`).

## Gates (host)

```bash
make "$PWD/build/test_overlay_png_golden" && ./build/test_overlay_png_golden; echo "true rc=$?"
make "$PWD/build/test_overlay_layout_fit" && ./build/test_overlay_layout_fit; echo "true rc=$?"
```
