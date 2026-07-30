# Idle / screensaver freeze — root cause + fix (host, no device)

| Field | Value |
|---|---|
| **TS_UTC** | 2026-07-30T18:30:00Z |
| **Lane** | host/ARM — no ssh/deploy/Quartus |
| **User report** | "current Plex version still has screensaver issues where it doesn't change" |

## Rule 0 — quoted facts

### Shipping / tip packaging still said PRESENT=fb0 (before this fix)

`scripts/package_release.sh` fallback conf and `assets/misterplex.conf.example`:

```text
PRESENT=fb0
```

Daemon defaults (before):

```text
// main.cpp
std::string presentMode = "fb0";
// media_player.hpp
std::string presentMode_ = "fb0";
```

### initPresent skipped FPGA for PRESENT=fb0 (before)

```cpp
bool wantFb = (presentMode_ == "fb0" || presentMode_ == "both" || presentMode_.empty());
bool wantFpga = (presentMode_ == "fpga" || presentMode_ == "both");
```

### Prior diagnosis never merged to this tip

Commit `145fd958` on `arm-deploy-candidate` / `w-bounce2` / `w-reliab-deaths` — **not** an ancestor of tip before this land:

> The frozen idle/screensaver the user hit twice came from PRESENT=fb0
> silently skipping fpga_.open(), so paintIdle never repainted the core
> DDR frame store the HDMI path scans out.

Partial mitigation `797210a1` **is** on tip (`paintIdle` open-on-demand). Product still shipped `PRESENT=fb0` in conf example/package.

### Lab conf ≠ shipping package

Recent device restore evidence used **PRESENT=fpga** (`docs/evidence/p480-headroom-20260730T170938Z/device_restored.txt`). That does not prove the user's daily conf.

## What is supposed to move

| Mode | IdleMode | Motion | Tick |
|---|---|---|---|
| Plex logo | 0 | **static** chevron | repaint every **30 s** (same pixels) |
| Black | 1 | flat black | 30 s |
| **Screensaver** | 2 | chevron **drifts** via `idlePhase_` | **100 ms** (~10 fps) |
| Last frame | 3 | no-op | no paint |

- Renderer: `host/libmisterplex/idle_screen.hpp`
- Painter: `MediaPlayer::paintIdle` → fb0 RGB **and** DDR I420
- Thread: `startIdle()` advances phase only for Screensaver

**Logo (default) is not supposed to "change."** Screensaver needs `IDLE_SCREEN=screensaver` or F12 `O[15:14]=2` with `OSD_CONTROL=1`.

## Second defect: first OSD word dropped idle bits

Before:

```cpp
return osdSeenBefore && osdIdleChanged(previousWord, word);
```

First successful OSD word never applied idle → Main's **persisted** F12 Screensaver was ignored after daemon restart.

## GDM hypothesis — REJECTED

`rg paintIdle|startIdle arm/misterplexd/companion.cpp` → **no matches**.  
`90a82208` cannot have driven idle animation (no call path).

## Fix landed

1. Default `PRESENT=fpga` (main + MediaPlayer + conf example + package_release).
2. `initPresent`: `wantFpga = true` for every non-none PRESENT.
3. Loud `ERROR` logs if FPGA open fails.
4. `shouldApplyOsdIdle`: **first word applies** persisted idle; later only on `[15:14]` change.
5. Unit: `test_present_default_fpga.sh` + OSD red twin `OSD_MENU_FAULT_SKIP_INITIAL_IDLE`.

## Gates (host, rc captured directly)

```text
bash tests/unit/test_present_default_fpga.sh  → true rc=0
./build/test_osd_menu                         → true rc=0
bash tests/unit/test_osd_menu_red.sh          → true rc=0
./build/test_last_frame_latch                 → true rc=0
```

## w-device recipe (when free — do not interrupt cast-from-.41)

```bash
# 0) Snapshot (read-only)
grep -E '^(PRESENT|OSD_CONTROL|IDLE_SCREEN|DECODE|STREAM)=' /media/fat/misterplex/misterplex.conf
md5sum /media/fat/linux/misterplexd /media/fat/_Utility/Plex.rbf
cat /tmp/CORENAME

# Pre-register:
# P1: PRESENT=fpga (or fb0 + log "also opening FPGA")
# P2: log has "idle screen painted" / "idle FPGA frame path OK"
# P3: Screensaver → two DDR dumps 1s apart differ (md5)
# P4: OSD_CONTROL=1 for F12 Idle Screen

# After parent-authorized deploy of fixed daemon+conf:
#   PRESENT=fpga
#   OSD_CONTROL=1
#   IDLE_SCREEN=screensaver   # or set F12 once
# Restart daemon only. Confirm:
grep -E 'PRESENT=|OSD_CONTROL|idle screen painted|ERROR idle|ERROR FPGA|idle FPGA' \
  /tmp/misterplexd.log | tail -40

# Motion without HDMI grabber: two bank0 dumps ~1s apart (method:
# docs/idle-screensaver-audit-v030.md A8). Expect md5 differ in Screensaver;
# equal in Logo.
```

## Residual

- Eyes-on HDMI not done here.
- Idle DDR still uses `plex480pDdrFrameGeometry()` while RGB idle is 320×240 — separate hygiene.
- Cast-from-.41 play failure is out of scope (w-device).
