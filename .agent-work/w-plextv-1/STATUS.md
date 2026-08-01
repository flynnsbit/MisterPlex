# w-plextv — DoD Playwright half (parent runbook)

**Tip:** `git -C .worktrees/w-plextv-e2e-fix rev-parse --short HEAD`  
Agent E2E ≠ evidence.

## Paste (zero placeholders; uses gitignored .env.lab)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

rk=27 full-bleed 480p:
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
E2E_TIER=480p PLEX_RATING_KEY=27 E2E_TRANSITION_CYCLES=10 \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

Red-path proof (no cast):
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
PLEX_BASE=http://192.168.1.24:32400 PLEX_TOKEN_FILE=/tmp/local_tok.txt \
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

## Assertions (daemon effect required)

| ID | Claim | Evidence |
|----|-------|----------|
| D1 | MiSTerPlex in Select Player (exact) | BEFORE/AFTER body diff |
| D2 | Companion local PMS | context request host |
| T1–T5 | play/pause/resume/seek/stop | :3005 timeline state+time |
| S1 | UI clock ≈ daemon time | ui_timeline.js |
| R1–R3 | cast-while-casting, stop-stopped, seek-past-end | daemon samples |
| P4 | idle after stop | timeline+resources+playing≠1 |
| Nav | **ratingKey only** | no title match |

## Red-before-green (measured)

| Proof | Result |
|-------|--------|
| P1 dead daemon | FAIL class |
| P2 dead PMS | UNVERIFIED |
| P6 bogus rk=999999991 | HTTP 404 → suite RED |
| P7 SHIELD .122 | preflight FAIL |

## NOT covered

Pixels/rows/overlay res/lipsync · PLXD frames (void until you lift) · agent-run as pass
