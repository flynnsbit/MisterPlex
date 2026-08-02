# w-plextv — household-hardened + measured geom (HDMI-blind)

## ≤10-line status
1. HDMI capture hard-faulted (parent) — Playwright is the working DoD half.
2. **COMPANION_INVARIANT** names selected host + friendlyName; fails with DIAGNOSIS when sort order breaks.
3. **N=10** transitions; one fail fails suite (`majority_pass_is_pass=0`).
4. **GEOM_TRIPLE**: requested_pms / library_media / measured — delivery_basis=measured only.
5. Parent class encoded: `624x480/624x480 → measured=624x350` = `pms_ceiling_desync`.
6. expectGeom=library while measured differs → FAIL (false-pass class).
7. TEARDOWN_OK our-controller only; user Plex tab must not fail suite.
8. Pure proofs `true rc=0`. Agent-run E2E ≠ evidence.

## Parent paste — pure proofs

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/measured_delivery.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

Expect P10 OK + `class=pms_ceiling_desync` rule line; all `true rc=0`.

## Parent paste — household-hardened E2E (you run)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
export PLEX_BASE="..."          # local PMS only
export PLEX_TOKEN_FILE="..."
export MISTER_HOST="..."
# Optional: EXPECT_COMPANION_FRIENDLYNAME="MiSTerPlex Studio"
# Optional pin real title: E2E_CLIENT_RATING_KEY=27|9|30
# Optional measured feed if telemetry 404:
#   E2E_DAEMON_LOG=...  E2E_LOG_CLEARED_BEFORE_CAST=1

E2E_TRANSITION_CYCLES=10 \
./tests/hw/e2e/run_household_hardened.sh; echo "true rc=$?"
```

Also: `./tests/hw/e2e/run_p7_real_title.sh` · `./tests/hw/e2e/run_pms_control_plane.sh` · `./tests/hw/e2e/run_n_media_health.sh`

## PRE_REGISTER
**PASS**
- `COMPANION_INVARIANT=PASS` + `COMPANION_SELECTED ... friendlyName=...`
- `TRANSITION_CYCLE_OK` × N and `TRANSITIONS_SUMMARY ... fail=0 majority_pass_is_pass=0`
- `MEASURED_DELIVERY_OK ... delivery_basis=measured` + `GEOM_TRIPLE ...`
- Real/P7 title path (not flash fixture) when content=real
- `TEARDOWN_OK controller=closed` · `CAST_PICKER_E2E_RESULT=PASS`

**FAIL**
- `wrong_companion_server` with offending friendlyName DIAGNOSIS
- any cycle fail · measured unprobed when require=1
- `expect_geom_is_library_claim` (624x350 class)

**NEVER**
- score library_media or requested_pms as delivery
- majority of N as pass · kill user tab · imply pixels from green Playwright

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
```
