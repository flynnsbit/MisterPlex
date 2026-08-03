# MAX_CMDS / HIT_SCAN cost (w-osd)

## Split: storage vs paint scan (pre-fit decision)

| Parameter | Product value | Role |
|-----------|--------------:|------|
| `MAX_CMDS` / `kMaxCmds` | **112** | List **storage** + loader/ABI depth |
| `HIT_SCAN` / `kHitScan` | **48** | Per-pixel `chrome_at` walk (combo cost) |

rd-duck yosys (w-osd HEAD): `MAX_CMDS=112` + `HIT_SCAN=48` → **35,541** generic cells
vs committed 112/112 = **77,749** (−42,208 / **−54.3%**). 112-store/48-scan vs 48/48
differs by only **+32** cells — **list depth is not the cost; HIT_SCAN is**.

### Runtime cmd inventory (HDMI_OUT 1280×720)

| Scenario | `totalUncapped` | fits HIT_SCAN=48? |
|----------|----------------:|:------------------:|
| Shipping daemon (`title=null`, `notice=null`, `buffering=false`) + huge skip | **41** | yes |
| Same shipping path, no skip | **30** | yes |
| Core STOPPED + 19-char title + bar | ~38 | yes |
| Prior “simultaneous short” (skip+notice+buf) | **79** | no (deferred) |
| True worst API caps (title19+notice31+H:MM:SS+huge skip+buf+full bar) | **~98–102** | no (deferred) |

Evidence: `media_player.cpp` `publishPlxcHud(..., nullptr)` — daemon never feeds
title/notice/buffering today. Gate: `test_plex_chrome_cmds` + `test_plex_chrome_hit_scan_static.sh`.

**Product feed** (`buildPlaybackHud`) truncates to **`kHitScan`**. Storage may still
hold 112 for ABI/loader; fabric paints only the first `HIT_SCAN` entries.

Full simultaneous 102-cmd UI is **deferred** to a scanline-indexed renderer
(HBLANK active list). Do **not** first-fit `HIT_SCAN=112`.

## Mailbox map (parent ABI freeze)

```
PLXC  +0x130
list  +0x140 .. +0x4BF   (112 × 8B = 0x380; storage)
PLXG  +0x800 FIXED       (NOT kPlxl + MAX_CMDS*8)
```

Bound only: `kPlxlOffset + kPlxcListMaxCmds*8 <= kPlxgOffset`.

## Yosys generic cell counts (not Quartus ALM / not Fmax)

| MAX_CMDS / HIT_SCAN | cells (approx) | notes |
|--------------------:|---------------:|-------|
| 48 / 48 | 35509 | baseline |
| **112 / 48** | **~35541** | **product pre-fit** (−54% vs 112/112) |
| 112 / 112 | 77749 | rejected for first fit |
| 128 / 128 | 88309 | — |

Combo depth of `chrome_at` scales on **`clk_hdmi`**. Fmax **UNKNOWN until Quartus**.

## Decision

1. First fit: **`MAX_CMDS=112`, `HIT_SCAN=48`** (`sys_top.v`, RTL defaults, `kHitScan`).
2. Merged gate: shipping runtime cmd count **≤48** (`fitsHitScan`).
3. Defer full 102-command simultaneous UI to scanline-indexed path.
