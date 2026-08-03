# Chrome path hunt: source-width ≥1280 defect class

**Lane:** w-osd · **Date:** 2026-08-03  
**Trigger:** parent bank bug `coded_w >= 1280` selected Option-C map while source is **960**.  
**Question:** does chrome/HUD/idle conflate coded 960×540 with glass 1280×720?

## Method

Grep + read of fabric chrome, PLXC ARM pack, idle paint, scorer — not lane-agree constants.

## Findings (quoted)

### Fabric RTL — CLEAN

`plex_chrome.sv` composites only from `HDMI_WIDTH`/`HDMI_HEIGHT` (beam).  
No `coded_w`, no `>= 1280` predicate, no hardcoded 1280 in executable RTL
(only comments). Idle chevron, cyan/magenta marks, demo HUD, lime beacon all
use HDMI_* .

### ARM PLXC — CLEAN defaults, hardened against poison

| Site | Behaviour |
|------|-----------|
| `chromeOutW_/H_` default | **1280×720** (`media_player.hpp`) |
| `publishPlxcHud` | uses `chromeOut*`, **not** `outW_/outH_` (decode) |
| `setChromeOutputSize` | existed with no callers from coded path; **now refuses** 960×540 / 624×480 / 960×544 / 320×240 |
| `publishPlxcHud` | **fail-closed reset** to kTarget if chromeOut is coded-class or below HDMI floor |
| `setDecodeSize` `w>1280` clamp | decode **max** clamp only — not a bank-map select; 960 passes through |

### ARM idle bake (plane off) — separate path

`paintIdle` uses `plex480pDdrFrameGeometry()` coded canvas when fabric plane is
**not** live. That is intentional ARM path, not HDMI chrome. When
`chromePlaneLive()`, idle/overlay pixel bake is skipped.

### PLXO

`readChromeHwPresent` only samples `chrome_hw` bit — does **not** currently
refine chromeOut from mon_w/h. Defaults 1280×720 remain. (If mon is wired later,
must feed HDMI mon_* only, never coded.)

### Unit coverage

- `checkHudIsOutputNotCoded` — HUD y on 720p bottom band  
- `checkCodedSizeRejectedForChrome` — coded sizes flagged; 960×540 HUD maxY&lt;540  

## ACTIVE gate vs coded 544 (SETTLED by parent SPS measurement 2026-08-03)

**Product path (ARM decode → bank):** libavcodec applies SPS crop before AVFrame.
Parent bitstream dump: coded height **544**, `frame_crop_bottom_offset=2` →
**4 lines** cropped → **540 display**. Payload **777,600 B**.  
**540 × 4/3 = 720 exactly** — no vertical crop on glass for this path.  
w-osd PASS-A does **not** need to design around a 5-line shortfall **on this path**.

**Where 544 still matters (not w-osd product glass):** fabric decoder / bitstream
ring consuming **coded** coefficients sees 544 lines / 783,360 B and must crop
4 bottom lines. That is w-mem ring ABI + future fabric decode — record only.

**General measurement honesty (unchanged):** PASS-A floor `ACTIVE_H≥680` still
cannot distinguish correct-720 from nearly-correct-715 after grabber scale.
That is a scorer precision limit, not a product-path crop bug.

## Beacon

`PLEX_FAB_PLAY_BEACON` already landed (`5c498b29`) — lime toggle, default OFF.
