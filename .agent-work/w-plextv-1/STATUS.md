# w-plextv — rate + 480p + companion invariant

## ≤10-line status
1. **CLIENT_RATE**: media/wall ratio gate — catches starved play that still advances.
2. Tolerance **derived**: min=0.75 from parent starved audio_s/wall_s=0.467 vs healthy=0.993; max=1.35.
3. Pause/seek steps excluded from rate pairs (red-proofed in selfCheck).
4. **480p arms**: fullbleed rk=27 (healthy), bbb352 rk=9 (collapse case).
5. **COMPANION_INVARIANT**: primary discovery host must be PLEX_BASE; names offending server.
6. TEARDOWN_OK our-controller only preserved.
7. Agent-run E2E ≠ evidence — parent runs commands below.
8. Pure proofs: `node client_truth.js` + `prove_red_paths.js` → expect true rc=0.

## Parent paste — pure red/green (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/client_truth.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

## Parent paste — 480p matrix (primary this session)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
PLEX_BASE=http://192.168.1.24:32400 \
PLEX_TOKEN_FILE=/tmp/local_tok.txt \
MISTER_HOST=192.168.1.183 \
E2E_TRANSITION_CYCLES=10 \
./tests/hw/e2e/run_480p_matrix.sh; echo "true rc=$?"
```

Single arms:
```bash
# healthy FullBleed
./tests/hw/e2e/run_480p_client_truth.sh fullbleed; echo "true rc=$?"
# collapse-case BBB 624x352 (may FAIL CLIENT_RATE if starvation reproduces)
./tests/hw/e2e/run_480p_client_truth.sh bbb352; echo "true rc=$?"
```

## Parent paste — generic client-truth (default tier=480p)

```bash
PLEX_BASE=http://192.168.1.24:32400 PLEX_TOKEN_FILE=/tmp/local_tok.txt \
MISTER_HOST=192.168.1.183 E2E_TRANSITION_CYCLES=10 \
./tests/hw/e2e/run_client_truth.sh; echo "true rc=$?"
```

## PRE_REGISTER
**PASS**
- `CLIENT_RATE_OK ratio≈0.99` continuous play
- `COMPANION_INVARIANT=PASS` primary=PMS-under-test
- `MISTERPLEX_IN_PICKER hitExact` ghost rejected
- transitions N + `TEARDOWN_OK controller=closed`

**FAIL**
- `client_realtime_rate_low` ratio&lt;0.75 (starved class; advance-only would pass)
- `wrong_companion_server` names offending friendlyName/sort
- UI stuck / seek miss / cast missing

**INVALID** ratingKey swap mid-window  
**NEVER_SCORE** daemon av-lock/drops/smoothness

## Artifacts
`build/e2e-480p-matrix-fullbleed/` · `build/e2e-480p-matrix-bbb352/` · `build/e2e-client-truth/`

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
```
