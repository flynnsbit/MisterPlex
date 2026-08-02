# w-plextv — S6 N-loop + P7 real title + race hardening

## Branch / tip
Worktree: `.worktrees/w-plextv-e2e-form`  
Branch: `w-plextv-cast-picker-e2e-form2`  
Agent-run E2E is **not** evidence — parent runs cast suite.

## What this tip adds (rd-review S6 / P7 / races)
1. **S6** — `E2E_TRANSITION_CYCLES=10` default; `run_s6_transitions.sh`; per-cycle rows; **one fail fails suite** (`majority_pass_is_pass=0`); failures name `cycle` + `transition`.
2. **P7** — `run_p7_real_title.sh` + `CAPTURE_WINDOW_OPEN/CLOSE` wall clocks; parent grab recipe in `run_p7_parent_capture.md`. Green Playwright ≠ P7 pixel-closed.
3. **Races** — spinner-aware `waitForDetailsReady`; distinct reasons:
   - `details_spinner_stuck`
   - `details_never_rendered`
   - `details_ready_title_only`
   - `play_button_not_found` (only when details painted)
   - `select_player_blocked_by_spinner` / `select_player_control_not_found`
4. Pure red proof **P12** in `prove_red_paths.js` / `race_taxonomy.js` (9/10 N-loop must RED).

## Pure proofs (agent OK)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/race_taxonomy.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

## Parent — S6 N=10 transitions (synthetic 240p path you already greened)
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
export PLEX_BASE="..." PLEX_TOKEN_FILE="..." MISTER_HOST="..."
./tests/hw/e2e/run_s6_transitions.sh; echo "true rc=$?"
# Expect: TRANSITION_CYCLE_OK 1..10, TRANSITIONS_SUMMARY pass=10 fail=0, TEARDOWN_OK
# Any TRANSITION_CYCLE_FAIL cycle=K transition=NAME → suite RED
```

## Parent — P7 real title + HDMI markers
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
export PLEX_BASE="..." PLEX_TOKEN_FILE="..." MISTER_HOST="..."
# Optional: E2E_P7_RATING_KEY=...  E2E_P7_CLEAR_WAIT_SEC=30
./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```
Watch for `CAPTURE_WINDOW_OPEN wall_ms=...` → start grab; `CAPTURE_WINDOW_CLOSE` → stop.
See `tests/hw/e2e/run_p7_parent_capture.md`.

If grabber dead (`Pixelclock: 0`): control-plane may PASS; **P7 glass stays INSUFFICIENT_EVIDENCE**.

## Parent — media-health N-loop (real content + supply_ratio)
```bash
./tests/hw/e2e/run_n_media_health.sh; echo "true rc=$?"
```

## What each assert catches
| Assert | Fails when |
|--------|------------|
| picker exact | MiSTer missing / only ghost `MiSTerPlexTest` |
| companion | primary friendlyName ≠ PMS under test |
| details_spinner_stuck | Play missing because spinner still owns pane |
| play_button_not_found | Details painted; selectors miss (not a load race) |
| TRANSITION_CYCLE_FAIL c/t | Named cycle+transition (pause/resume/seek/stop/…) |
| N aggregate | pass≠N or fail>0 (9/10 is RED) |
| CLIENT_RATE | UI timeline ratio starved (parent 0.467 class) |
| TEARDOWN | our controller left (never kills user tab) |
| P7 capture hold stop | Session died mid parent grab window |
| pixels on glass | **never suite PASS** |

## Standing traps
- `context.on('request')` not `page.on`
- Select User gate first
- `a[aria-label="Select Player"]` not Cast
- Whole-page "MiSTerPlex" is FP (library name)
- rc=77/78 never pass; capture `true rc=$?` directly
