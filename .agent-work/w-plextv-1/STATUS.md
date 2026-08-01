# w-plextv runbook (parent paste)

## Self-diagnosing harness

`./tests/hw/e2e/run_cast_picker.sh` runs `preflight_env.js` first:
- missing PLEX_BASE/TOKEN → **FAIL rc=1** + remediation (never soft-pass)
- PMS down → **UNVERIFIED rc=2**
- no playwright/chromium → **SKIP-NOT-PASS rc=77**
- Auto token files: `PLEX_TOKEN_FILE`, `/tmp/local_tok.txt`, `~/.config/misterplex/plex_token`
- Auto lab env: `tests/hw/e2e/.env.lab` or `~/.config/misterplex/e2e.env` (gitignored)
- `PLEX_WEB_USER` optional — empty → first Home profile, logs `PLEX_WEB_USER_DEFAULTED=<name>`
- `MISTER_HOST` defaults to lab MiSTer when unset

## Paste commands (zero placeholders if .env.lab present)

Full N=10 (control plane):
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

Overlay-only (long chrome windows for HDMI — use this for low-res overlay bug):
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-plextv-e2e-fix
E2E_OVERLAY_ONLY=1 E2E_OVERLAY_HOLD_SEC=10 E2E_OVERLAY_REPEATS=2 \
E2E_OUTPUT_W=1920 E2E_OUTPUT_H=1080 \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

Align capture on log lines:
- `PAUSE_OVERLAY_WINDOW_OPEN wall_ms=… hold_ms=…`
- `PAUSE_OVERLAY_WINDOW_CLOSE wall_ms=…`
- `SCRUB_OVERLAY_WINDOW_OPEN/CLOSE`
- `PAUSE_AFTER_SCRUB_WINDOW_OPEN/CLOSE`
- `OVERLAY_CONTRACT output=WxH chrome_must_match_OUTPUT_not_content=1`

If preflight fails without .env.lab:
```bash
export PLEX_BASE=http://192.168.1.24:32400
export MISTER_HOST=192.168.1.183
export PLEX_TOKEN_FILE=/tmp/local_tok.txt
# optional: export PLEX_WEB_USER=YourProfileName
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

## Profile name

How to find: open Plex Web Home → "Select User" names. Suite logs options at `user_picker clicking profile=… options=…`. Pin with `PLEX_WEB_USER`.

## Boundary

Playwright ≠ pixels/rows. PLXD void until parent glass-confirms post-fit RBF.
