# Fabric OSD / idle layout — paint beam, three domains

## Principle

HUD, idle chevron, screensaver span, demo STOPPED panel, and PLAYING beacon
geometry are derived from the **paint beam** domain — the raster the module is
wired into — never from STORAGE bank size alone, and never from a frozen 480p
canvas.

See **`docs/fab-chrome-paint-domain.md`** for the ascal-pivot decision.

## Three domains

| Domain | Product size | Role |
|--------|--------------|------|
| STORAGE | 960×540 bank | DDR payload — not chrome |
| CORE_DE | 960×540 DE | core→ascal — pre-ascal only |
| HDMI_OUT | 1280×720 | **Product chrome** (post-ascal) |

Product path: PMS **960×540** → ARM decode → CORE_DE → **ascal** → glass
**1280×720** → **plex_chrome** paints HDMI_OUT → osd → pins
(`sys_top.v`: ascal → shadowmask → plex_chrome → osd).

## RTL (`plex_chrome.sv`)

| Signal | Role |
|--------|------|
| `layout_w/h` | Paint canvas = beam, unless FAULT forces wrong domain |
| `body_scale` | `body_scale_f(layout_h)` — half-even H/240 (3 @ 720p, 2 @ 540p) |
| `glass_scale` / `mon_*` | Always true beam (monitor/keep-sink unchanged) |
| Cyan / magenta corner sigs | True beam corners (capture contract) |

Faults (sim only):

- `FAULT_LEGACY_480P_LAYOUT=1` — beam 1280×720; paint 624×480 origins
- `FAULT_HDMI_LAYOUT_ON_CORE_DE=1` — beam 960×540; paint 1280×720 math

## Host (`plex_chrome_cmds.hpp`)

- `kHdmiOutW/H = 1280×720`, `kCoreDeW/H = 960×540`, `kStorageW/H = 960×540`
- `PaintDomain::{Storage,CoreDe,HdmiOut}`
- `chromeLayoutFromActiveHdmi()` — product HDMI_OUT only; refuses 960×540
- `chromeLayoutFromPaintDomain(CoreDe, …)` — pre-ascal experiment only
- `buildPlaybackHud` bottom band y ≥ 572 on 720p HDMI_OUT

## Tests

| Test | What it catches |
|------|-----------------|
| idle720 red | mon ports clamped to 480p |
| idle720 legacy | 480p paint on 720p beam |
| idle720 **hdmi_on_de** | HDMI 720p paint on CORE_DE 540 beam |
| idle720 corede | green pre-ascal 960×540 layout |
| idle720 green | product HDMI_OUT 720p |
| cmds `checkPaintDomains` | host domain refuse / CoreDe opt-in |
| fabchrome legacy | demo panel dense mid-band, not y≥600 |

## Math

**HDMI_OUT 1280×720 (product):** size=240; ox=520; oy=240; body_scale=3; panel ~572+  
**CORE_DE 960×540 (pre-ascal only):** size=180; ox=390; oy=180; body_scale=2
