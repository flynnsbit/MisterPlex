# w-plextv — Playwright half of definition of done

**Branch:** `w-plextv-cast-picker-e2e-fix2`  
**Worktree:** `.worktrees/w-plextv-e2e-fix`  
**Tip:** `git rev-parse --short HEAD`  
**Agent E2E runs are NOT evidence.** Parent runs only.

---

## HARD BOUNDARY (read this first)

| Playwright **can** prove | Playwright **cannot** prove |
|--------------------------|------------------------------|
| MiSTerPlex in Select Player (exact, not ghost) | What HDMI shows |
| Companion server chosen by `_pickCompanionServer` | Overlay / chrome **resolution** (user low-res bug) |
| UI play/pause/resume/seek/stop + :3005 state effect | Judder, frame loss, lipsync |
| UI clock ≈ daemon timeline time | Correct pixels of decode |
| Device returns idle (P4 :3005) after stop | Idle **logo** pixels (you score glass) |
| Daemon pid stable across N-loop | PLXD frames/presents/drops on live RBF |

**A green Playwright run is never proof the video was correct.** Only parent HDMI-USB capture settles video. Present path is **529×240** only — no fine-detail assertions.

**PLXD void (live RBF `c5382bee`):** `frames_done` packs `bank_vsync_count` (`ddr_frame_store.sv:1004`). Suite defaults **`E2E_PLXD_FRAMES_VOID=1`** — residual/presents/drops are **not** pass criteria. pid/session/playing still gated. Set `E2E_PLXD_FRAMES_VOID=0` only after a fixed RBF.

Companion **:3005** — `/resources`, timeline poll, `/player/telemetry`. **No `/status`.**

---

## What the suite drives (real Plex Web UI → local PMS)

1. Select User → library item → **Select Player** → exact **MiSTerPlex**
2. Play → :3005 `playing` + time advances + UI clock match  
3. **Pause** → `paused` + time frozen + UI clock + **`GLASS_EXPECT picture=pause_overlay`** (`defect_hint=pause_overlay_low_res`)  
4. Resume → playing + advances  
5. **Seek/scrub** UI scrubber → land near target + advances + `play_chrome` glass join  
6. Seek back  
7. Stop → idle + **P4_IDLE_OK**  
8. Idle → play again  
9. N cycles (default 10); TEARDOWN our browser only; force idle end  

Glass pair lines (parent join):
- `GLASS_EXPECT` / `GLASS_JOIN` with `wall_ms` + `daemon_time_ms` + `ui_time_ms`
- `PAUSE_OVERLAY_WINDOW_OPEN/CLOSE` — capture chrome res here  
- `E2E_GLASS_HOLD=1` blocks suite for full `hold_ms` during markers  

---

## Commands (you run)

### API soak (more reliable than UI for soaks)
```bash
export MISTER_HOST=… PLEX_BASE=http://192.168.1.24:32400 \
  PLEX_TOKEN_FILE=/tmp/local_tok.txt PLEX_MACHINE_ID=… \
  PLEX_KEY=/library/metadata/13
./scripts/parent_cast_local.sh play; echo "true rc=$?"
./scripts/parent_cast_local.sh stop; echo "true rc=$?"
./scripts/parent_cast_local.sh idle-check; echo "true rc=$?"
```
(Session `files/parent_cast_local.sh` is **not** in repo → rc=127.)

### Playwright DoD
```bash
cd .worktrees/w-plextv-e2e-fix
E2E_TIER=480p E2E_TRANSITION_CYCLES=10 E2E_REQUIRE_PID=1 E2E_REQUIRE_UI_TIMELINE=1 \
E2E_PLXD_FRAMES_VOID=1 E2E_PAUSE_OVERLAY_HOLD_MS=4000 \
PLEX_BASE=http://192.168.1.24:32400 PLEX_TOKEN_FILE=/tmp/local_tok.txt \
PLEX_WEB_USER=<profile> MISTER_HOST=<mister> \
PLEX_KEY=/library/metadata/13 \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

**Pre-register:** `true rc=0` · `pass==10` · `transition_pause_ok` · `PAUSE_OVERLAY_WINDOW_*` · `P4_IDLE_OK` · `TEARDOWN_OK` · device idle logo.

**rc:** 0 PASS · 1 FAIL · 2 UNVERIFIED · 77 SKIP-NOT-PASS (never pass).

---

## Parent-proven vs tip

| SHA | Evidence |
|-----|----------|
| `93fa0c04` | Parent: N=1 picker+transitions+TEARDOWN rc=0 |
| tip | Needs your N=10 + pause_overlay + P4 run |

---

## NOT covered

- HDMI pixels / overlay resolution / judder  
- PLXD frames_done residual (void)  
- Lipsync / av-lock  
- SHIELD / remote PMS  
- Agent-run as pass  
