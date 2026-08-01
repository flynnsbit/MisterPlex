# w-plextv — definition-of-done Playwright half (honest)

**Tip SHA:** see `status.txt`  
**Branch:** `w-plextv-cast-picker-e2e-fix2`  
**Worktree:** `.worktrees/w-plextv-e2e-fix`  
**Agent E2E runs are not evidence.**

## T3 — Harness

| | Path | Role | Reliability |
|--|------|------|-------------|
| **API soak** | **`scripts/parent_cast_local.sh`** (repo) | play/stop/status/idle-check on :3005 | **More reliable** for soaks than Web UI |
| **Playwright DoD** | `tests/hw/e2e/run_cast_picker.sh` | Real picker + transport + device asserts | **DoD path**; heavier |

Session `files/parent_cast_local.sh` is **not in repo** → `cd repo && bash files/...` → **rc=127**. Use **`scripts/parent_cast_local.sh`** (env-only hosts/tokens).

```bash
export MISTER_HOST=… PLEX_BASE=http://YOUR-PLEX-SERVER:32400 PLEX_TOKEN=… PLEX_MACHINE_ID=…
./scripts/parent_cast_local.sh play; echo "true rc=$?"
./scripts/parent_cast_local.sh stop; echo "true rc=$?"
./scripts/parent_cast_local.sh idle-check; echo "true rc=$?"
```

## T1 — Device-paired control path

UI action → :3005: playing/paused/frozen/seek land/stop + companion host + exact picker.  
`GLASS_EXPECT` = what you should see on HDMI (suite does not score pixels).  
Idle glass contract: **IDLE_SCREEN=logo** (static Plex logo).

## T2 — P4 STOPPED

After stop/cycle end/suite end: timeline idle + `/resources` 200 + telemetry `playing≠1` → **`P4_IDLE_OK`**.

## Parent-proven

Only `@93fa0c04` N=1 picker+transitions+TEARDOWN. Tip needs your N=10 + P4 run.

## T4 — NOT covered

- Pixels / judder / frame-loss % (ERROR **18** and **19 WITHDRAWN** — do not cite 1.54%/0.07% as measured)
- Lipsync / av-lock
- Logo pixels (conf contract only)
- Daemon restart (you restart; re-run suite)
- SHIELD / remote PMS / plex.tv player reg / agent E2E as evidence

## Playwright

```bash
cd .worktrees/w-plextv-e2e-fix
E2E_TIER=480p E2E_TRANSITION_CYCLES=10 E2E_REQUIRE_PID=1 E2E_REQUIRE_UI_TIMELINE=1 \
PLEX_BASE=http://YOUR-PLEX-SERVER:32400 PLEX_TOKEN=<tok> PLEX_WEB_USER=<profile> \
MISTER_HOST=<mister> ./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```
Pre-reg: rc=0, pass==10, P4_IDLE_OK, TEARDOWN_OK, idle daily-driver.
