# Fabric OSD / idle layout — active canvas, not 480p constants

## Principle

HUD, idle chevron, screensaver span, demo STOPPED panel, and PLAYING beacon
geometry are derived from the **active HDMI/output raster** (`HDMI_WIDTH` /
`HDMI_HEIGHT`), never from coded bank size (960×540) or a frozen 480p canvas.

Product path: PMS **960×540** → ARM decode → fabric upscale → glass **1280×720**.
Chrome paints in **output** pixels (`9b28290b`).

## RTL (`plex_chrome.sv`)

| Signal | Role |
|--------|------|
| `layout_w/h` | Paint canvas = HDMI, unless `FAULT_LEGACY_480P_LAYOUT` |
| `body_scale` | `body_scale_f(layout_h)` — half-even H/240 (3 @ 720p) |
| `glass_scale` / `mon_*` | Always true HDMI (monitor/keep-sink unchanged) |
| Cyan / magenta corner sigs | True HDMI corners (capture contract) |

`FAULT_LEGACY_480P_LAYOUT=1` (sim only): DE stays 1280×720; paint uses 624×480
origins. Red-twin: amber at (232,160), **not** at 720p origin (520,240).

## Host (`plex_chrome_cmds.hpp`)

- `kTargetOutW/H = 1280×720`
- `chromeLayoutFromActiveHdmi()` — refuses 624×480 / 960×540 / coded sizes
- `buildPlaybackHud` bottom band y ≥ 572 on 720p

## Tests

| Test | What it catches |
|------|-----------------|
| `test_plex_chrome_idle720_rtl_sim` red | mon ports clamped to 480p |
| same, `IDLE720_MODE=legacy` | 480p-derived paint on 720p DE |
| `test_plex_chrome_fabchrome_rtl_sim` legacy | demo panel dense mid-band, not y≥600 |
| `test_plex_chrome_cmds` `checkLayoutFromActiveHdmi` | host refuse 480p/coded canvas |

## 720p math (product)

- chevron `size = min(W,H)/3` → 240; `ox=(1280-240)/2=520`; `oy=240`
- `body_scale(720)=3`
- demo panel `py0 = layout_h - ph - margin` → bottom band (~572+)
