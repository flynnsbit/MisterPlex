# Plex Web cast-picker e2e (Playwright)

Drives the **real Plex Web UI** against a **LOCAL PMS** and verifies MiSTerPlex as a
cast target. This is the regression gate for “Select Player shows only Cast…”.

API-only checks do **not** satisfy this suite — Playwright is mandatory.

## What it asserts

1. Launch Plex Web on `PLEX_BASE` and establish a session (token injection).
2. Open the **MiSTerPlex Tests** library item (default title match: `MiSTerPlex Test 240p`).
3. Open **Select Player** and **fail** if `MiSTerPlex` is missing (screenshot + clear reason).
4. Select MiSTerPlex, start Play, confirm companion timeline `state=playing`.
5. Best-effort pause; stop via UI or companion HTTP.

Failure messages distinguish:

| Reason | Meaning |
|--------|---------|
| `picker_did_not_contain_MiSTerPlex` | Companion-server / FriendlyName issue — see `docs/select-player-runbook.md` |
| `playback_did_not_start` | Picker OK; cast/play path broken |
| `select_player_control_not_found` | UI layout/selector drift |

## Prerequisites

- Node.js 18+
- Local PMS with the test library and token that can open Plex Web
- MiSTer companion reachable for playback asserts (`MISTER_HOST`, default lab host)

```bash
cd tests/hw/e2e
npm install
npx playwright install chromium
```

## One command

```bash
PLEX_BASE=http://YOUR-PLEX-SERVER:32400 PLEX_TOKEN=… \
  ./tests/hw/e2e/run_cast_picker.sh
```

Or via Make (same env):

```bash
make e2e-cast-picker
```

Optional overrides:

| Env | Default | Role |
|-----|---------|------|
| `PLEX_BASE` | conf `PLEX_BASE` | **LOCAL** PMS only — never remote/SHIELD |
| `PLEX_TOKEN` | conf `PLEX_TOKEN` | Web session |
| `PLEX_LIBRARY_NAME` | `MiSTerPlex Tests` | Section title substring |
| `PLEX_ITEM_TITLE` | `MiSTerPlex Test 240p` | Item title substring |
| `PLEX_RATING_KEY` | (discover) | Skip library search |
| `CAST_TARGET_NAME` | `MiSTerPlex` | Picker label |
| `PLEX_WEB_USER` | (first profile) | Plex Home “Select User” profile name |
| `MISTER_HOST` / `MISTER_PORT` | lab defaults | Companion timeline |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` | auto/cache | Chrome for Testing binary |
| `PW_HEADED=1` | off | Headed browser |
| `E2E_OUT` | `build/e2e-artifacts` | Screenshots |

Conf fallback: `MISTERPLEX_CONF` or `~/.config/misterplex/misterplex.conf`.

## Exit codes

| rc | Meaning |
|----|---------|
| 0 | PASS |
| 1 | FAIL (picker or playback) |
| 77 | SKIP-NOT-PASS — missing deps/env/PMS (not green) |

Soft-skip is **not** a pass. A missing MiSTerPlex in the picker is always **FAIL**.

## Secrets

Never commit `PLEX_TOKEN` or private `*:32400` addresses. `tests/unit/test_no_private_data.sh`
scans the tree. Use env or a gitignored conf file.

## Related

- `docs/select-player-runbook.md` — companionServer / FriendlyName diagnosis
- `docs/v2-video-baseline.md` — Plex Web picker mechanism (bundle citations)
