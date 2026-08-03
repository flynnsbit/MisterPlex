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

## ACTIVE gate vs ~5-line crop (parent coded-540 → 16-align 544 question)

PASS-A requires `ACTIVE_H >= 680`. A **5-line** shortfall on a true 720 content
height (e.g. 715 vs 720) **still PASSes** with large margin (35 lines).  

`FULLFILL` (scorer flag: ACTIVE ≥1240×700) is a coarse near-full hint only —
still will not reliably flag 5 lines after grabber scale into 1920×1080.  

**Honest answer:** this contract distinguishes control letterbox (923×717) from
full-ish fill (≥1100×680). It does **not** distinguish correct 720 from
nearly-correct 715. A MB-align crop bug that only drops a few lines is
**invisible** to PASS-A. Owning that precision is w-scaler/w-mem geom + a
tighter glass metric (or known pattern edges), not the loose PLAYING A gate.

## Beacon

`PLEX_FAB_PLAY_BEACON` already landed (`5c498b29`) — lime toggle, default OFF.
