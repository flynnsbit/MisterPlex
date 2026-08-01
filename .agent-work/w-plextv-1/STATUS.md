# w-plextv — Playwright half of definition of done

**Branch:** `w-plextv-cast-picker-e2e-fix2` · **Worktree:** `.worktrees/w-plextv-e2e-fix`  
**Tip:** `git rev-parse --short HEAD` · Agent E2E ≠ evidence.

## Fleet facts absorbed (parent glass, RBF c5382bee)

| Fact | Implication for this lane |
|------|---------------------------|
| Vertical row ceiling **proven** (even/odd solid invert, std=0; `store_y=py*2`) | Suite never claims rows reached glass; after w-geom T7 parent re-scores solid-field card |
| Horizontal 529-of-640 | **Arithmetic only** — not glass-proven; suite does not assert column count |
| `frames_done` = vsync counter | `E2E_PLXD_FRAMES_VOID=1`; never PASS on residual/presents/drops |
| `presents`/`drops` = ARM call/supply | Not display claims |
| `unaccounted` = residual twice | Not independent |
| `p_ge50` / dual-instrument | WITHDRAWN — do not cite |
| Stale detector blind when swaps stuck | Not Playwright-visible; note only |

**Standing rule:** every field name logged with its derivation (suite startup `FLEET_FACT field_derivations`).

## BOUNDARY

Playwright = Plex Web control-plane + `:3005` session (playing/paused/seek/idle/pid).  
**Not** pixels, rows, chrome res, judder, lipsync. Parent HDMI only for video.

## Covered (control plane)

Picker exact MiSTerPlex · companion · play/pause/resume/seek/stop · UI clock · N=10 · P4 idle · TEARDOWN · `GLASS_JOIN`/`pause_overlay` for parent chrome-res join.

## Commands (parent)

```bash
cd .worktrees/w-plextv-e2e-fix
E2E_TIER=240p E2E_TRANSITION_CYCLES=10 E2E_REQUIRE_PID=1 E2E_PLXD_FRAMES_VOID=1 \
PLEX_BASE=http://192.168.1.24:32400 PLEX_TOKEN_FILE=/tmp/local_tok.txt \
PLEX_WEB_USER=<profile> MISTER_HOST=<mister> \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```
Device conf is user-owned (`DECODE=320x240` live) — do not mutate for green.  
Pre-reg: rc=0, pass==N, P4_IDLE_OK, TEARDOWN_OK, PAUSE_OVERLAY_WINDOW_*, FLEET_FACT lines present.

API soak: `./scripts/parent_cast_local.sh play|stop|idle-check` (env-only).

## NOT covered

Rows/columns on glass · overlay res · PLXD as video · agent E2E as pass · SHIELD/remote.
