# w-plextv — N-loop media health (S6)

## ≤10-line status
1. **N=10 default**; one fail fails suite (no average). `TRANSITIONS_SUMMARY majority_pass_is_pass=0`.
2. **MEDIA_HEALTH** per cycle: `supply_ratio>=0.90`, `|av_drift_ms|<=75`, `clock=` present.
3. Tolerance **derived**: collapsed 0.72/+133 vs healthy 0.99/−30 (parent-measured).
4. **PID change → INVALID** cycle (respawn re-zeroes drops/presents).
5. `clock=av-lock` is still a **literal** (ERROR 20) — scored as field presence, NON_DISCRIMINATING value.
6. COMPANION_INVARIANT + TEARDOWN_OK our-only preserved.
7. Live device today: `/player/telemetry` **404** — need redeploy of enriched telemetry **or** `E2E_DAEMON_LOG=`.
8. Agent-run ≠ evidence. Pure selfCheck `true rc=0` below.

## Parent paste — pure proofs (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
node tests/hw/e2e/media_health.js; echo "true rc=$?"
node tests/hw/e2e/client_truth.js; echo "true rc=$?"
node tests/hw/e2e/prove_red_paths.js; echo "true rc=$?"
```

## Parent paste — N=10 media health E2E (you run)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form

# Optional if telemetry still 404 on device — parent-fed log snip (ERROR 12: clear before cast):
# export E2E_DAEMON_LOG=$PWD/build/e2e-n-media-health/daemon_snip.txt

PLEX_BASE=http://192.168.1.24:32400 \
PLEX_TOKEN_FILE=/tmp/local_tok.txt \
MISTER_HOST=192.168.1.183 \
E2E_TRANSITION_CYCLES=10 \
./tests/hw/e2e/run_n_media_health.sh; echo "true rc=$?"
```

Pins: `E2E_CLIENT_RATING_KEY=27` fullbleed · `9` collapse case · `30` long BBB.

## PRE_REGISTER
**PASS**
- `TRANSITION_CYCLE_OK` × N and `TRANSITIONS_OK cycles=N/N`
- `MEDIA_HEALTH_OK` each cycle `supply_ratio≥0.90` `|drift|≤75`
- `DAEMON_PID_OK` same pid entire run
- `COMPANION_INVARIANT=PASS` · `TEARDOWN_OK controller=closed`
- `CAST_PICKER_E2E_RESULT=PASS`

**FAIL**
- any cycle `media_supply_ratio_low` / `media_drift_unbounded` / UI transition fail
- `media_health_unprobed` without telemetry or E2E_DAEMON_LOG
- wrong primary companion

**INVALID**
- `daemon_pid_changed` mid-suite — never score counters across respawn

**NEVER**
- average 9/10 as pass · kill user Plex tab · score av-lock *value* as health

## Daemon note (parent deploy)
Worktree `telemetryLine()` now emits `av_drift_ms` `supply_ratio` `clock` `audio_s` `pid`.
Live binary currently 404s `/player/telemetry` — redeploy misterplexd from this tip OR feed log.

## SHA
```bash
git -C /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form rev-parse --short HEAD
```
