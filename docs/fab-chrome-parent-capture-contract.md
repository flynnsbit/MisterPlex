# FAB_CHROME parent capture contract (pre-registered)

**Lane:** w-osd · tip family after `02fd3b58`  
**Macro:** `PLEX_FAB_CHROME` default **OFF**  
**Mutually exclusive with** `PLEX_FAB_IDLE` (if both set, **IDLE wins**).  
Parent owns device capture. Numbers below are **before** any glass photo.

---

## 1. Enable path (integration only)

| Knob | Where | Value |
|------|-------|-------|
| Macro | `Plex.qsf` | Uncomment `VERILOG_MACRO "PLEX_FAB_CHROME=1"` |
| Do **not** also enable | `PLEX_FAB_IDLE` | Idle would mask chrome demo |
| Runtime conf | optional | `CHROME_PLANE=1` only matters when PLXO live (fail-closed) |
| ARM | — | Demo needs **no** daemon paint; strongest arm kills misterplexd by **PID** |

Default OFF: `chrome_demo_en=0`, `chrome_sig_en=0` → video passthrough (1-cycle delay only).

---

## 2. What you should see (PASS picture)

| Element | Spec |
|---------|------|
| Underlay | Whatever is on `din` (bars / last video / dark) — **not** full idle canvas |
| Panel | Dark navy bar `#141428` along the **bottom** of the HDMI active area |
| Text | White **STOPPED** (fabric font, scale from HDMI_H; @720p scale=3) |
| Progress | Grey track + **50% amber** `#FFB220` fill (fixed demo fraction) |
| **Fabric signature** | **Magenta `#FF2D95` L-brackets at TR + BL** (64×12). Idle uses cyan TL+BR — different corners **and** colour. |
| Motion | **None** in demo (static HUD). Idle milestone owns motion. |

### ARM playback overlay control (must NOT match PASS)

| Element | ARM `playback_overlay.hpp` |
|---------|----------------------------|
| Colours | black / white / amber — **no pure magenta FF2D95** |
| Magenta corners | **Never** → `MAGENTA_PX ≈ 0` |
| Canvas | Often 624×480 content bake |
| Log | per-frame bake path; no `PLXC publish` required for pixels |

---

## 3. Capture commands + PASS / FAIL

```bash
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-chrome-t0.png
# Strong ARM-out (use PID, not killall):
ssh root@$MISTER_HOST 'pidof misterplexd'   # note PID
ssh root@$MISTER_HOST 'kill <PID>'          # specific PID only
sleep 2
scripts/hdmi_capture_idle.sh docs/agent-evidence/fab-chrome-nodaemon.png
```

### PASS (all)

| Metric | PASS |
|--------|------|
| **MAGENTA_PX** | **≥ 1500** |
| **ORANGE_PX** | **≥ 200** (amber bar; may be lower than idle chevron) |
| **MEAN** | **> 5** (not full black) |
| **CYAN_PX** | **≈ 0** (idle signature off) |
| Daemon stopped | still magenta + panel + STOPPED |

### FAIL

| Observation | Meaning |
|-------------|---------|
| MAGENTA=0, amber/white high | ARM overlay bake, not fabric |
| CYAN high, magenta 0 | Wrong macro (FAB_IDLE) |
| MEAN=0 | Black / grabber |
| Dies when daemon killed | Fabric demo not on |

---

## 4. ARM out of the paint loop (product path)

When plane live (`chromePlaneLive`):

- `presentCleanFrame` **does not** `renderOverlay` (pixel bake)
- `publishPlxcHud` only from `showPlaybackOverlay` (**state change**), not every N frames
- Demo macro does not need ARM at all

Negative test (unit): `test_plex_chrome_cmds` — live gate leaves frame bytes unchanged.

---

## 5. Sim evidence

```
tests/unit/test_plex_chrome_fabchrome_rtl_sim.sh
  RED  FAULT_NO_FAB_CHROME → pure video, mag=0
  GREEN demo+sig → magenta + STOPPED white + amber + panel + video underlay
```
