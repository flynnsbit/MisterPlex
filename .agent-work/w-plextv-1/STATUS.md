# w-plextv — P7 real-title path (Contract 3)

## Last finished (≤10 lines)
- Worktree restored; suite half already had P7 windows + N=10 + teardown.
- **Fixed** `isFixtureMeta` section-wide reject of "MiSTerPlex Tests" (blocked FullBleed/BBB).
- P7 auto-discovers **w-asset480 Contract 3** by path/title (FullBleed / Real BBB GlassAV).
- Live PMS probe (measured): default → **rk=28 1440x1080** BBB; `E2E_P7_ARM=fullbleed` → rk=27.
- **Viewed pixels = parent only. Green Playwright ≠ P7 closed.**

## Branch / SHA
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form
git rev-parse --short HEAD && git log -1 --oneline
```

## Parent paste — P7 (you run; agent-run ≠ evidence)

Uses lab env / token file via preflight. **No rk pin** = Contract3 auto-discover.

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-form

# Optional ERROR-12: E2E_P7_CLEAR_WAIT_SEC=30 then truncate LIVE log;
# export E2E_LOG_CLEARED_BEFORE_CAST=1 and E2E_DAEMON_LOG=$PWD/build/e2e-p7/daemon_snip.txt

PLEX_BASE="${PLEX_BASE:?set LOCAL PMS e.g. http://YOUR-LOCAL-PMS:32400}" \
PLEX_TOKEN_FILE="${PLEX_TOKEN_FILE:-/tmp/local_tok.txt}" \
MISTER_HOST="${MISTER_HOST:?set MiSTer host}" \
E2E_TRANSITION_CYCLES=10 \
E2E_P7_HOLD_SEC=45 \
./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```

Lab one-liner (caller-supplied topology — not committed as CI default):

```bash
# Parent shell already has lab values; example only:
# PLEX_BASE=http://<local-pms>:32400 PLEX_TOKEN_FILE=/tmp/local_tok.txt MISTER_HOST=<mister> \
#   ./tests/hw/e2e/run_p7_real_title.sh; echo "true rc=$?"
```

Or rely on gitignored `tests/hw/e2e/.env.lab` / preflight defaults for MISTER_HOST + token file.

### Optional pins (caller-supplied)
| Intent | Env |
|--------|-----|
| FullBleed 1200s (asset480) | `E2E_P7_ARM=fullbleed` or `E2E_P7_RATING_KEY=27` |
| Long BBB bank | `E2E_P7_RATING_KEY=30` |
| Non-bank scale stress | `E2E_P7_ARM=nonbank` or rk 32/29/28 |
| Default auto | omit pin → highest Contract3 score (probe: rk=28 1440x1080) |

## Artifacts
- `build/e2e-p7/p7_cast_manifest.json`
- `build/e2e-p7/p7_events.jsonl`
- `build/e2e-p7/e2e_run_id.txt`
- Markers: `P7_SELECTED_ITEM`, `discover_p7_ok`, `CAST_WINDOW_*`, `CAPTURE_WINDOW_*`, `TEARDOWN_OK`

## HDMI
During `CAPTURE_WINDOW_OPEN`..deadline; discard ~15 warmup frames. Suite never opens `/dev/video0`.

## Guarantees
Exact cast + ghost reject; companion sort diagnosis; our-controller teardown only; rc=77 never PASS.

## NOT suite
Viewed pixels (P7 close), overlay res, judder, lipsync, PLXD frames.
