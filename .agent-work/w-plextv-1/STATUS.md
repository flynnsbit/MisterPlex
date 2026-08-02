# w-plextv — PMS control-plane (HDMI-blind DoD half)

## ≤10-line status
1. **HDMI capture locked out** (parent: Active width 0) — Playwright + PMS HTTP is the working DoD half.
2. **pms_control_plane.js**: `/status/sessions` + `/transcode/sessions` scorers (play/pause/gone + tc speed).
3. Parent samples encoded: HEALTHY complete=1 progress=99.7 speed=19.8 · COLLAPSED complete=0 progress=68.6 speed=0.
4. **Stale hygiene**: OUR player leftover after stop → FAIL; transcoder-only → REPORT (user long-lived tab safe).
5. **BOUNDARY banner** every run: green ≠ viewed pixels. Control plane only.
6. **Lean Chromium** default (workstation CPU-contended; suite can perturb playback).
7. COMPANION_INVARIANT + TEARDOWN_OK our-controller-only preserved.
8. Pure selfCheck + prove_red P9 `true rc=0`. Agent-run E2E ≠ evidence.

## What this settles / does not
| Settles | Does NOT settle |
|---------|-----------------|
| MiSTer in Select Player (exact) | Any correct pixel on glass |
| PMS session playing correct ratingKey | Smoothness / A/V lip-sync |
| Pause/stop reflected on PMS | Delivered geometry on wire |
| Transcoder not speed=0 collapse class | HDMI-USB viewed frames |
| Stale OUR session after stop | User tab transcoder ownership |

## Parent paste — pure proofs (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/pms_control_plane.js; echo "true rc=$?"
node tests/hw/e2e/client_truth.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

Expect: `pms_control_plane.js selfCheck OK`, `PROOF P9 OK`, `CAST_PICKER_GATE_RED_PATHS=PROOF_OK`, all `true rc=0`.

## Parent paste — PMS control-plane E2E (you run)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form

# Required env — never commit tokens/IPs (test_no_private_data):
#   PLEX_BASE       local PMS only (Docker on this host OK)
#   PLEX_TOKEN_FILE path to token file
#   MISTER_HOST     cast target host

export PLEX_BASE="..."          # local PMS URL only — not SHIELD, not remote
export PLEX_TOKEN_FILE="..."
export MISTER_HOST="..."

# Optional pin: E2E_CLIENT_RATING_KEY=27 (FullBleed) | 9 (BBB collapse case) | 6 (short 480p)
E2E_TRANSITION_CYCLES=5 \
E2E_CLIENT_RATING_KEY=27 \
./tests/hw/e2e/run_pms_control_plane.sh; echo "true rc=$?"
```

Also still valid: `./tests/hw/e2e/run_client_truth.sh`, `./tests/hw/e2e/run_n_media_health.sh` (media health needs redeployed telemetry or `E2E_DAEMON_LOG`).

## PRE_REGISTER
**PASS**
- `MISTERPLEX_IN_PICKER=true hitExact=true` (ghost rejected)
- `PMS_SESSION ... mode=playing` ratingKey match
- `PMS_TRANSCODE` speed≥0.5 (or empty + allowEmpty direct-play)
- `PMS_SESSION ... mode=paused` then `gone` after stop
- `PMS_STALE_HYGIENE` clean OR tc-only report (not our player leftover)
- `TEARDOWN_OK controller=closed browser=closed stop_ok=1`
- `BOUNDARY_PLAYWRIGHT` / `EVIDENCE_CLASS=control_plane_not_pixels` in log
- `CAST_PICKER_E2E_RESULT=PASS` · `true rc=0`

**FAIL**
- session missing / wrong rk / pause not on PMS
- leftover OUR status session after stop
- transcoder speed=0 collapse class when sessions present
- companion primary ≠ expected PMS friendlyName order
- any transition cycle fail (one in N fails suite)

**UNVERIFIED (rc=2)** — PMS unreachable (not a pass)

**SKIP-NOT-PASS (rc=77)** — missing token/chromium (never green)

**NEVER**
- imply pixels from green Playwright
- kill user long-lived Plex tab
- soft-pass rc=77 · average N-loop · score daemon `clock=av-lock` value (ERROR 20)

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
```
