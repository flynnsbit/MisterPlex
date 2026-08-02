# w-plextv — client-truth DoD + P7 handoff

## ≤10-line status
1. Playwright half of DoD: **client-observed** cast + transport (UI clock + PMS sessions rk).
2. **ERROR 20:** never score daemon `av-lock`/drops/smoothness — observational only.
3. Real BBB on local PMS section 2 (rk 9–10,18–19,27–32); Other Videos empty.
4. Default P7 discover → long BBB (often rk=10 720×480 ~597s); pins 28/30/32 available.
5. `run_client_truth.sh` = N=10 transitions, clientTruth=1, daemon effects OFF.
6. Red-before-green: `node client_truth.js` + `prove_red_paths.js` (selfCheck).
7. TEARDOWN_OK our-controller only; force idle end (daily driver / logo).
8. **Green suite ≠ P7 closed** — parent must VIEW pixels in CAPTURE_WINDOW.

## Parent paste — CLIENT TRUTH (primary DoD run)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form

# Pure red proofs (no device) — expect true rc=0
node tests/hw/e2e/client_truth.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"

# Full client-truth E2E (you run; agent-run ≠ evidence)
PLEX_BASE=http://192.168.1.24:32400 \
PLEX_TOKEN_FILE=/tmp/local_tok.txt \
MISTER_HOST=192.168.1.183 \
E2E_TRANSITION_CYCLES=10 \
./tests/hw/e2e/run_client_truth.sh; echo "true rc=$?"
```

Pins: `E2E_CLIENT_RATING_KEY=30` long bank · `28` 1440 short · `32` 720×480 scale path.

## PRE_REGISTER (client truth)
**PASS**
- `MISTERPLEX_IN_PICKER=true hitExact=true` (ghost MiSTerPlexTest REJECTED)
- `CLIENT_PLAY_OK` UI position advances; `CLIENT_PAUSE` frozen; seek near+advances
- `CLIENT_STOP` UI idle; `CLIENT_RK_GATE` rk_before==rk_after each phase
- `TRANSITIONS_OK` N cycles; `TEARDOWN_OK controller=closed browser=closed stop_ok=1`
- `CAST_PICKER_E2E_RESULT=PASS`

**FAIL**
- UI stuck / seek miss / still advancing after stop / cast missing from picker
- Companion sort collision diagnosis if MiSTer absent (name before "misterplex studio")

**INVALID (never data)**
- `rating_key_changed` / session unprobed mid-window (respawn/content swap)

**NEVER_SCORE**
- daemon av-lock, drops, pfps, smoothness, A/V sync, PLXD frames

**IDLE_END**
- suite force-stops cast; daily driver returns to static logo (not screensaver)

## Parent paste — P7 capture window (viewed pixels)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
PLEX_BASE=http://192.168.1.24:32400 \
PLEX_TOKEN_FILE=/tmp/local_tok.txt \
MISTER_HOST=192.168.1.183 \
E2E_TRANSITION_CYCLES=10 \
E2E_P7_HOLD_SEC=45 \
./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```

Artifacts: `build/e2e-client-truth/` · `build/e2e-p7/p7_cast_manifest.json` · `p7_events.jsonl`

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form branch --show-current
```
