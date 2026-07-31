# Plex Web cast-picker e2e (Playwright)

Drives the **real Plex Web UI** against a **LOCAL PMS** and verifies MiSTerPlex as a
cast target. This is the regression gate for “Select Player shows only Cast…”.

API-only checks do **not** satisfy this suite — Playwright is mandatory.

## What it asserts

1. Launch Plex Web on `PLEX_BASE` and establish a session (token injection).
2. Dismiss Plex Home **Select User** (shell never renders until a profile is chosen).
3. Open the **MiSTerPlex Tests** library item (default title match: `MiSTerPlex Test 240p`).
4. Open **Select Player** (`a[aria-label="Select Player"]` — not “Cast”).
5. **Picker contents via BEFORE/AFTER body-text diff** — whole-page search for
   `MiSTerPlex` is a **false positive** (library / item / server names). Only lines
   that appear *after* the picker opens count.
6. **Which companion server Web polled** — `context.on('request')` captures
   `/clients` + `/neighborhood/devices` (page-level listeners miss them). Host must
   match `PLEX_BASE` (or `EXPECT_COMPANION_HOST`). This is the FriendlyName sort-order
   regression gate.
7. Select MiSTerPlex, start Play, confirm companion timeline `state=playing`.
8. Optional **HDMI motion** stage (`E2E_HDMI_MOTION=1`) — parent captures; suite scores.
9. Best-effort pause; stop via UI or companion HTTP.
10. **Hard teardown** — blank page, close page/context/browser, force companion stop,
    assert timeline is quiescent (`TEARDOWN_OK`). Dirty teardown is a **FAIL**.

Failure messages distinguish:

| Reason | Meaning |
|--------|---------|
| `picker_did_not_contain_MiSTerPlex` | Companion-server / FriendlyName issue — see `docs/select-player-runbook.md` |
| `picker_clicked_non_exact_target` | Ghost label (e.g. `MiSTerPlexTest`) nearly matched — exact name required |
| `wrong_companion_server` | Web polled a different owned PMS than `PLEX_BASE` (sort-order fragility) |
| `companion_discovery_not_observed` | No `/clients` traffic on context listener after opening picker |
| `details_never_rendered` | Item details still loading/spinner — race, not a missing Play selector |
| `play_button_not_found` | Details ready; Play control selector drift |
| `playback_did_not_start` | Picker OK; cast/play path broken |
| `select_player_control_not_found` | UI layout/selector drift |
| `teardown_device_not_quiescent` | Browser/controller left daemon playing/paused after exit |
| `hdmi_motion_no_frames` | HDMI stage on but capture dir empty (parent must grab) |
| `hdmi_motion_unscored` | Instrument rc=77 — hard FAIL in this gate |
| `hdmi_motion_freeze` / `hdmi_motion_color_fail` | Instrument rc=1 / rc=2 |

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
| `EXPECT_COMPANION_HOST` | host of `PLEX_BASE` | Companion assert allow-list (comma-separated) |
| `ASSERT_COMPANION` | `1` | `0` = log companion only (SKIP-NOT-PASS for that check; not a green companion gate) |
| `ALLOW_LOOPBACK_COMPANION` | allow `127.0.0.1` | Set `0` to require non-loopback match |
| `MISTER_HOST` / `MISTER_PORT` | lab defaults | Companion timeline |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` | auto/cache | Chrome for Testing binary |
| `PW_HEADED=1` | off | Headed browser |
| `E2E_OUT` | `build/e2e-artifacts` | Screenshots |
| `E2E_HDMI_MOTION` | `0` | `1` = optional pixel gate via parent HDMI capture |
| `E2E_HDMI_CAPTURE_DIR` | `build/e2e-hdmi-capture` | PNG burst dir (parent-filled) |
| `E2E_HDMI_HOLD_SEC` | `20` | Hold `playing` so parent can capture |
| `E2E_HDMI_WARMUP_SKIP` | `15` | Passed to motion instrument |
| `E2E_HDMI_VIDEO_DEV` | `/dev/video0` | **Parent only** — printed in capture cmd |

Conf fallback: `MISTERPLEX_CONF` or `~/.config/misterplex/misterplex.conf`.

## Exit codes

| rc | Meaning |
|----|---------|
| 0 | PASS (includes verified `TEARDOWN_OK`) |
| 1 | FAIL (picker, companion, playback, teardown, or HDMI motion) |
| 77 | SKIP-NOT-PASS — missing deps/env/PMS (not green) |

Soft-skip is **not** a pass. A missing MiSTerPlex in the picker is always **FAIL**.
Instrument `rc=77 UNSCORED` under `E2E_HDMI_MOTION=1` is a **hard FAIL**.

## Interference warning — do not run during soak / CPU windows

This suite drives real Plex Web as a cast **controller**. While the browser is open it
long-polls `/player/timeline/poll?wait=1` and can issue pause/stop. That **will corrupt**
concurrent playback, CPU sampling, and soak measurements on the same daemon.

- Do **not** run this suite while a soak, HDMI motion burst for another test, or parent
  CPU window is in progress on the same MiSTer.
- Teardown must log `TEARDOWN_OK` (timeline not playing/paused). If you see
  `teardown_device_not_quiescent`, treat the device as dirty until manually stopped.
- Default path force-stops the companion and closes the browser context even on failure.

## Optional HDMI motion stage (parent-owned grabber)

When `E2E_HDMI_MOTION=1`, after timeline `playing` the suite:

1. Prints `PARENT_HDMI_CAPTURE_CMD` and `PARENT_HDMI_SCORE_CMD` (exact commands).
2. Holds playback for `E2E_HDMI_HOLD_SEC` so the **parent** can capture.
3. **Never opens `/dev/video0`** (exclusive parent hardware).
4. If `E2E_HDMI_CAPTURE_DIR` already contains PNGs, runs
   `tools/hdmi_motion_instrument.py` and requires `MOTION_OK` (rc=0).

```bash
# Terminal A — suite (holds playing ~20s when HDMI stage on)
E2E_HDMI_MOTION=1 E2E_HDMI_CAPTURE_DIR=build/e2e-hdmi-capture \
  E2E_HDMI_HOLD_SEC=25 \
  PLEX_BASE=… PLEX_TOKEN=… PLEX_RATING_KEY=3 PLEX_WEB_USER=… \
  ./tests/hw/e2e/run_cast_picker.sh
echo "true rc=$?"

# Terminal B — parent, during HDMI_HOLD (from suite log PARENT_HDMI_CAPTURE_CMD)
mkdir -p build/e2e-hdmi-capture
ffmpeg -y -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 50 build/e2e-hdmi-capture/f_%04d.png
```

If the capture dir is empty at score time → `hdmi_motion_no_frames` (FAIL, not skip).

## Topology note

Do **not** encode one household’s multi-PMS LAN (e.g. a SHIELD IP) into CI. The suite
asserts portable behavior: Web’s chosen `companionServer` must be the `PLEX_BASE` you
pointed at. Wrong companion ⇒ FriendlyName ordering — see the runbook.

## Secrets

Never commit `PLEX_TOKEN` or private `*:32400` addresses. `tests/unit/test_no_private_data.sh`
scans the tree. Use env or a gitignored conf file.

## Related

- `docs/select-player-runbook.md` — companionServer / FriendlyName diagnosis
- `docs/v2-video-baseline.md` — Plex Web picker mechanism (bundle citations)
- `tools/hdmi_motion_instrument.py` — burned-in counter / green-cast scorer
