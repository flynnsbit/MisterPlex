# w-plextv — control-plane DoD (HDMI-blind, w-avsync exits)

## Status
1. HDMI capture dead — Playwright is the only automated E2E channel.
2. **QUALITY_POLICY=VERIFY_CONTROL_NOT_QUALITY** — ~25% intermittent degrade; N=1 healthy ≠ quality.
3. Exit codes aligned with w-avsync: **0 PASS · 1 FAIL · 78 INSUFFICIENT_EVIDENCE · 79 SESSION_INVALID · 77 NO-DATA**.
4. Soft-skip is never pass. Absence is NO-DATA, never 0.0.
5. No lab-IP defaults (MISTER_HOST/PLEX_BASE env only).
6. Pure proofs `true rc=0`. Agent cast E2E ≠ evidence — parent runs device path.

## Pure proofs (agent OK)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/evidence_codes.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

## Parent E2E (evidence — you run)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
export PLEX_BASE="..."          # local PMS only — not SHIELD, not remote
export PLEX_TOKEN_FILE="..."
export MISTER_HOST="..."

./tests/hw/e2e/run_control_plane_dod.sh; echo "true rc=$?"
```

Optional pin: `E2E_CLIENT_RATING_KEY=3` (240p) or `27` / `9` (480p).

## What each assert catches (must be able to fail)

| id | fails when | rc |
|----|------------|-----|
| pms_reachable | web/identity not OK | 78 |
| mister_in_picker | exact name missing; ghost only | 1 |
| companion_invariant | primary companion ≠ PMS under test | 1 |
| session_playing_rk | PMS sessions wrong/missing rk | 1 |
| pause_reflected | UI still advances / PMS not paused | 1 |
| stop_gone | our session still on PMS after stop | 1 |
| ratingKey_stable | rk swap mid-run | 79 |
| teardown_our_only | our controller left polling | 1 |
| playback_quality | **OUT OF SCOPE** (default) | — |

## PASS means
Control plane: browse → cast → session → transitions → stop clean + TEARDOWN_OK.
**Not** vfps/drops/supply quality. **Not** pixels.

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
```
