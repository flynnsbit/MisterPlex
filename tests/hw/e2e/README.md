# Plex Web cast-picker e2e (Playwright)

Drives the **real Plex Web UI** against a **LOCAL PMS** and verifies MiSTerPlex as a
cast target. This is the regression gate for “Select Player shows only Cast…”.

API-only checks do **not** satisfy this suite — Playwright is mandatory.

## What it asserts

1. Launch Plex Web on `PLEX_BASE` and establish a session (token injection).
2. Dismiss Plex Home **Select User** (shell never renders until a profile is chosen).
3. Open the tier library item (`E2E_TIER=240p` → RK3, `480p` → **RK8** Soak 480p
   24fps by default; never silently substitute a fixture for real-content mode).
4. Open **Select Player** (`a[aria-label="Select Player"]` — not “Cast”).
5. **Picker contents via BEFORE/AFTER body-text diff** — whole-page search for
   `MiSTerPlex` is a **false positive** (library / item / server names). Only lines
   that appear *after* the picker opens count.
6. **Which companion server Web polled** — `context.on('request')` captures
   `/clients` + `/neighborhood/devices` (page-level listeners miss them). Host must
   match `PLEX_BASE` (or `EXPECT_COMPANION_HOST`). This is the FriendlyName sort-order
   regression gate.
7. Select **exact** `MiSTerPlex` (ghost labels like `MiSTerPlexTest` are logged and
   **rejected**), start Play, confirm companion timeline `state=playing`.
8. **Multi-cycle transitions** (`E2E_TRANSITION_CYCLES`, default **10**): each cycle
   asserts pause (timeline **frozen**), resume (timeline **advances**), seek (lands
   near target then advances), stop→idle, idle→play. HTTP 200 alone is never enough.
   Failure names `transition_cycle_<N>_<transition>`.
9. **Frame ledger** (default on): `GET /player/telemetry` or `E2E_DAEMON_LOG` —
   `residual == frames - presents - drops`, session stable mid-cycle (daemon
   self-exit/respawn → `ledger_session_changed`). Soft-skip ≠ residual PASS.
10. Optional **HDMI motion** (`E2E_HDMI_MOTION=1`) — parent captures `/dev/video0`;
   suite scores with `tools/hdmi_motion_instrument.py` (MOTION_OK / FREEZE /
   COLOR_FAIL / **STRUCTURE_FAIL rc=3** / UNSCORED). Default: **per-cycle** capture
   dir + hold. Suite **never** opens the grabber. `rc=77` is hard FAIL for synthetic
   fixtures; real content uses timeline + color/structure only.
11. **Hard teardown** — blank page, close page/context/browser, suite stop +
    unsubscribe. Asserts **this suite’s controller is gone** (`TEARDOWN_OK`). Does
    **not** require a globally idle daemon (a permanent user Plex Web tab may remain).

### NOT pass criteria (fleet 2026-07-31 — binding)

- **`clock=av-lock` and `av_drift_ms` are NOT evidence of A/V correctness.** They
  read the servo setpoint back to itself (`AV_PRESENT_LEAD_MS` deadband). Measured:
  three soaks with mean `av_drift_ms` within 0.8 ms of each other were **~120 ms
  apart at HDMI**. This suite **never** gates on them and must not start.
- **Lip-sync judge (parent only):** `tools/avsync_measure_hdmi.py` on a real capture.
  w-plextv does not open `/dev/video0`.
- Startup drop count alone is not a lip-sync model (H-DROP rejected).

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
| `daemon_tier_unprobed` | Tier requires parent conf probe (`E2E_DAEMON_DECODE`) — not applied |
| `daemon_tier_mismatch` | Parent conf/decode does not match `E2E_TIER` |
| `transition_cycle_N_*` | Cycle N failed at named transition (pause/resume/seek/stop/play_idle_play) |
| `transition_*` | Pause/resume/seek effect failure (time still advancing / not advancing) |
| `teardown_controller_not_closed` | Suite browser/context failed to close |
| `real_content_item_unspecified` | `E2E_CONTENT=real` without PLEX_RATING_KEY / title |
| `hdmi_motion_no_frames` | HDMI stage on but capture dir empty (parent must grab) |
| `hdmi_motion_unscored` | Instrument rc=77 — hard FAIL for synthetic/motion mode |
| `hdmi_motion_freeze` / `hdmi_motion_color_fail` / `hdmi_motion_structure_fail` | rc=1 / rc=2 / rc=3 |
| `ledger_unprobed` | No `/player/telemetry` and no parseable `E2E_DAEMON_LOG` (require=1) |
| `ledger_residual_nonzero` | frames−presents−drops not accounted |
| `ledger_session_changed` | daemon session id changed mid-cycle (self-exit/respawn) |
| `ledger_lifetime_regressed` | lifetime_frames went backwards mid-cycle |

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
# capture true rc DIRECTLY:
#   ./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

Or via Make (same env):

```bash
make e2e-cast-picker
```

### Decode tiers (240p / 480p)

| `E2E_TIER` | Default RK | Expect decode | Parent conf (suite never applies) |
|------------|------------|---------------|-------------------------------------|
| `240p` (default) | 3 | `320x240` | `DECODE=320x240` |
| `480p` | 6 | `624x480` | `DECODE=624x480` `DECODE_ALLOW_LAB_480P=1` `DDR_YUV_FORCE_SCALE=1` |
| `all` | both | both | run only after parent can satisfy each tier’s probe |

The suite **prints** `PARENT_TIER_EXPORT=…` and conf instructions; it does **not** ssh or
edit `/media/fat/misterplex/misterplex.conf`.

After parent applies conf and restarts the daemon, export the banner/probe value:

```bash
# 480p example (parent-run)
export E2E_TIER=480p
export E2E_DAEMON_DECODE=624x480   # required for 480p (else daemon_tier_unprobed FAIL)
PLEX_BASE=… PLEX_TOKEN=… PLEX_WEB_USER=… MISTER_HOST=… \
  ./tests/hw/e2e/run_cast_picker.sh
echo "true rc=$?"
```

- `E2E_REQUIRE_DAEMON_TIER=1` forces the probe even for 240p.
- Mismatch → `daemon_tier_mismatch` (loud fail; does not silently test the wrong tier).

Optional overrides:

| Env | Default | Role |
|-----|---------|------|
| `PLEX_BASE` | conf `PLEX_BASE` | **LOCAL** PMS only — never remote/SHIELD |
| `PLEX_TOKEN` | conf `PLEX_TOKEN` | Web session |
| `E2E_TIER` | `240p` | `240p` / `480p` / `all` |
| `E2E_DAEMON_DECODE` | (none) | Parent probe of daemon decode (`320x240` / `624x480`) |
| `E2E_DAEMON_DECODE_240P` / `_480P` | (none) | Per-tier probes when `E2E_TIER=all` |
| `E2E_REQUIRE_DAEMON_TIER` | tier default | `1` = always require probe |
| `E2E_TRANSITIONS` | `1` | `0` = skip transition stress block |
| `E2E_TRANSITION_CYCLES` | `10` | Repeat pause/resume/seek/stop-idle-play this many times (1 = smoke) |
| `E2E_CONTENT` | `synthetic` | `real` = non-fixture library item (requires RK/title); HDMI counter optional |
| `E2E_HDMI_EVERY_CYCLE` | `1` if HDMI on | `0` = score first+last cycle only |
| `E2E_HDMI_ASSERT` | auto | `motion` (synthetic) or `color_structure` (real) |
| `E2E_HDMI_SOURCE_FPS` | `23.976` | Passed to instrument rate check |
| `E2E_HDMI_CAPTURE_FPS` | `30` | Passed to instrument rate check |
| `E2E_LIVE_CONF` | (none) | Parent-exported live `--conf` path from `/proc/<pid>/cmdline` |
| `E2E_LIVE_DAEMON_ID` | (none) | Parent-exported live daemon id/sha (logged only) |
| `PLEX_LIBRARY_NAME` | `MiSTerPlex Tests` | Section title substring |
| `PLEX_ITEM_TITLE` | tier default | Item title substring (single-tier override) |
| `PLEX_RATING_KEY` | tier default | Skip library search (single-tier override) |
| `CAST_TARGET_NAME` | `MiSTerPlex` | Picker label (exact match only) |
| `PLEX_WEB_USER` | (first profile) | Plex Home “Select User” profile name |
| `EXPECT_COMPANION_HOST` | host of `PLEX_BASE` | Companion assert allow-list (comma-separated) |
| `ASSERT_COMPANION` | `1` | `0` = log companion only (not a green companion gate) |
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
| 0 | PASS (includes verified `TEARDOWN_OK` for **this** controller) |
| 1 | FAIL (picker, companion, playback, tier, transition, teardown, or HDMI) |
| 77 | SKIP-NOT-PASS — missing deps/env/PMS (not green) |

Soft-skip is **not** a pass. A missing MiSTerPlex in the picker is always **FAIL**.
Instrument `rc=77 UNSCORED` under `E2E_HDMI_MOTION=1` is a **hard FAIL**.

## Interference warning — do not run during soak / CPU windows

This suite drives real Plex Web as a cast **controller**. While the browser is open it
long-polls `/player/timeline/poll?wait=1` and can issue pause/stop. That **will corrupt**
concurrent playback, CPU sampling, and soak measurements on the same daemon.

- Do **not** run this suite while a soak, HDMI motion burst for another test, or parent
  CPU window is in progress on the same MiSTer.
- Teardown must log `TEARDOWN_OK` (suite browser closed + stop issued). If you see
  `teardown_controller_not_closed`, treat the host as still holding a Playwright controller.
- A permanent **user** Plex Web tab on the LAN is **not** this suite’s controller; teardown
  does not fail solely because the daemon still shows activity from that tab.
- Default path force-stops via companion HTTP (suite commandID namespace) and closes the
  browser context even on failure.

## Optional HDMI motion stage (parent-owned grabber)

When `E2E_HDMI_MOTION=1`, after timeline `playing` (and transitions if enabled) the suite:

1. Prints `PARENT_HDMI_CAPTURE_CMD` and `PARENT_HDMI_SCORE_CMD` (exact commands).
2. Holds playback for `E2E_HDMI_HOLD_SEC` so the **parent** can capture.
3. **Never opens `/dev/video0`** (exclusive parent hardware; discard ~11–15 warm-up frames
   via `--warmup-skip`).
4. If `E2E_HDMI_CAPTURE_DIR` already contains PNGs, runs
   `tools/hdmi_motion_instrument.py` and requires `MOTION_OK` (rc=0).

```bash
# Terminal A — suite (holds playing ~20s when HDMI stage on)
E2E_HDMI_MOTION=1 E2E_HDMI_CAPTURE_DIR=build/e2e-hdmi-capture \
  E2E_HDMI_HOLD_SEC=25 E2E_TRANSITIONS=0 \
  E2E_TIER=240p E2E_DAEMON_DECODE=320x240 \
  PLEX_BASE=… PLEX_TOKEN=… PLEX_WEB_USER=… \
  ./tests/hw/e2e/run_cast_picker.sh
echo "true rc=$?"

# Terminal B — parent, during HDMI_HOLD (from suite log PARENT_HDMI_CAPTURE_CMD)
mkdir -p build/e2e-hdmi-capture
ffmpeg -y -v error -f v4l2 -input_format mjpeg -video_size 1920x1080 \
  -i /dev/video0 -frames:v 50 build/e2e-hdmi-capture/f_%04d.png
```

If the capture dir is empty at score time → `hdmi_motion_no_frames` (FAIL, not skip).

Instrument exit codes (suite mapping):

| instrument rc | meaning | suite |
|---------------|---------|--------|
| 0 | MOTION_OK | PASS (synthetic requires this) |
| 1 | FREEZE | FAIL |
| 2 | COLOR_FAIL | FAIL |
| 3 | STRUCTURE_FAIL | FAIL |
| 77 | UNSCORED | FAIL if `E2E_HDMI_ASSERT=motion`; allowed for `real`/`color_structure` when color/structure clean |

Per-cycle dirs: `E2E_HDMI_CAPTURE_DIR/cycle_01` … `cycle_N` when multi-cycle + HDMI on.

### Real content (`E2E_CONTENT=real`)

Synthetic avsync fixtures carry burned-in `TREK24`/`NTSC2397` counters. Real titles do not.
For real content the suite asserts:

- Picker / companion / exact cast / play start (same as synthetic)
- **Timeline effect** on every transition cycle (freeze / advance / seek land / stop idle)
- HDMI (if enabled): COLOR_FAIL + STRUCTURE_FAIL still hard-fail; missing counter → UNSCORED is OK
- Parent may still view a frame by eye from the capture dir

```bash
E2E_CONTENT=real E2E_TIER=240p E2E_DAEMON_DECODE=320x240 \
  PLEX_RATING_KEY=<real> PLEX_LIBRARY_NAME='Your Library' \
  E2E_TRANSITION_CYCLES=10 E2E_HDMI_MOTION=0 \
  PLEX_BASE=… PLEX_TOKEN=… PLEX_WEB_USER=… \
  ./tests/hw/e2e/run_cast_picker.sh
echo "true rc=$?"
```

### Live daemon / conf (two install roots)

This device has had **two** install roots and **two** conf files. The suite never ssh’s
and never assumes `/media/fat/misterplex/`. Parent should resolve the live process:

```bash
pid=$(pidof misterplexd | awk '{print $1}')
tr '\0' ' ' < /proc/$pid/cmdline; echo
conf=$(tr '\0' ' ' < /proc/$pid/cmdline | sed -n 's/.*--conf[= ]\([^ ]*\).*/\1/p')
export E2E_LIVE_CONF=$conf
export E2E_DAEMON_DECODE=…   # from that conf / banner
```

### Multi-cycle stress (default 10)

```bash
E2E_TRANSITION_CYCLES=10 E2E_TIER=240p E2E_DAEMON_DECODE=320x240 \
  PLEX_BASE=… PLEX_TOKEN=… PLEX_WEB_USER=… MISTER_HOST=… \
  ./tests/hw/e2e/run_cast_picker.sh
echo "true rc=$?"
# Look for TRANSITIONS_SUMMARY cycles=10 pass=10 fail=0
```

A single cycle failure prints `CYCLE N/10 FAILED at transition=…` and fails the run.

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


## P7 — Real library content cast (`make e2e-real-content`)

Pixel-verifies a **genuine** (non-fixture, **non-bank-geometry**) title on the
**LOCAL** PMS only. Ignores SHIELD / `plex.nevertrustaf.art`. **Never** falls
back to `MiSTerPlex Tests` avsync fixtures or to `library_media` of `320x240` /
`624x480` (those only prove "fixture at bank size").

```bash
# 1) Parent: apply 480p conf from LIVE --conf (two install roots — resolve via /proc)
# 2) Parent: CLEAR daemon log + ffmpeg.err BEFORE play (correlation)
# 3) Discover + cast + hold (capture recipe prints ONLY after SESSION_ESTABLISHED)
cd .worktrees/w-plextv-e2e-fix   # or repo root with this branch
E2E_TIER=480p E2E_DAEMON_DECODE=624x480 E2E_REAL_HOLD_SEC=45 \
E2E_SESSION_WALL_MS=3000 \
PLEX_BASE=http://YOUR-LOCAL-PMS:32400 PLEX_TOKEN=… PLEX_WEB_USER=… \
MISTER_HOST=… \
./tests/hw/e2e/run_real_content.sh; echo "true rc=$?"

# Multi-cycle transitions on synthetic (default N=10):
E2E_TIER=240p E2E_DAEMON_DECODE=320x240 E2E_TRANSITION_CYCLES=10 \
PLEX_BASE=… PLEX_TOKEN=… PLEX_WEB_USER=… MISTER_HOST=… \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

### Fail-loud discovery

| Reason | Meaning |
|--------|---------|
| `real_content_library_empty` | No non-fixture titles |
| `real_content_no_nonbank_geometry` | Only bank-sized non-fixtures |
| `real_content_is_fixture` | Explicit RK is lab fixture |
| `real_content_bank_geometry` | Explicit RK is 320x240/624x480 |
| `session_not_established` | Timeline never reached threshold — **do not capture** |

### Delivered geometry (measurement, not request)

Daemon change: rawvideo ffmpeg spawn uses `-loglevel info` and re-logs
`media: DELIVERED_GEOM stream=WxH source=ffmpeg.err` (Stream #0:0 banner).

```bash
# After PLAY, on device:
grep -E 'DELIVERED_GEOM|GEOM |wall_s=' LIVE_LOG | tail -40
export E2E_DELIVERED_GEOM=1440x1080   # or
export E2E_DAEMON_LOG=/path/to/cleared_snip.txt
export E2E_REQUIRE_DELIVERED_GEOM=1   # hard-fail if unmeasured
```

`expected_delivery` in GEOM_CHAIN is a **request**. PMS upperBound is a ceiling.

### Parent HDMI recipe (falsifiable)

Suite logs `PARENT_HDMI_CAPTURE_CMD` **only after** `SESSION_ESTABLISHED`
(timeline `time >= E2E_SESSION_WALL_MS`, default 3000). Capturing earlier caused
`rc=77 UNSCORED` on idle/chevron — that is **never** a pass.

| Fail signature | What you see |
|----------------|--------------|
| WRAP | horizontal wrap / mirrored edge columns |
| H_DUP | side-by-side duplicated panels |
| CHROMA_MAGENTA | magenta/green UV corruption or solid green cast |
| PILLAR_WRONG | active width ~half / wrong AR vs `library_media` |
| FULLWIDTH_CORRUPT | smashed full-bleed AR |
| FREEZE | identical frames while timeline `time` advances |

Pass: recognizable motion/detail; AR consistent with `library_media` fitted into
the decode bank without the signatures above. Counter `MOTION_OK` does **not**
apply without TREK overlay. Instrument `rc=77` is hard FAIL when `E2E_HDMI_MOTION=1`.

### Teardown / concurrency

- Closes **our** Playwright controller only; does not require global controller-free
  (user's long-lived Plex Web tab must not fail the suite).
- **Do not run during soak/CPU windows** — cast interferes with concurrent playback.

### Transitions N-cycle (S6)

`E2E_TRANSITION_CYCLES` default **10**. Each cycle:
1. **Resets** (force stop + play from beginning) — seek residual from prior cycle is cleared;
   logs `CYCLE_START_STATE time0_ms=…`.
2. pause / resume / seek@8000 / stop / idle→play with **timeline effect** asserts.
3. Logs `TRANSITION_CYCLE_OK|FAIL` per cycle.

Default `E2E_TRANSITION_CONTINUE_ON_FAIL=1` when N>1: a mid-run fail does **not**
silently shorten the planned N — remaining cycles still run; aggregate PASS requires
`pass==N fail==0`. Failure names `transition_cycle_K_<transition>`.

### Transitions N-cycle

`E2E_TRANSITION_CYCLES` default **10**. Per-cycle pause/resume/seek/stop/replay
with timeline **effect** asserts. Failure names `transition_cycle_K_<transition>`.


## Tiers (240p / 480p)

| E2E_TIER | ratingKey | item | expect DECODE |
|----------|-----------|------|---------------|
| `240p` (default) | 3 | MiSTerPlex Test 240p | 320x240 |
| `480p` | **8** | MiSTerPlex Soak 480p 24fps | 624x480 |
| `all` | both | sequential | parent conf per tier |

Suite never edits device conf. Device may already be `DECODE=624x480` (user-owned);
export `E2E_DAEMON_DECODE` to match live banner or suite fails `daemon_tier_mismatch`.

```bash
# 480p arm (rk=8 soak) + 10 transition cycles + ledger
E2E_TIER=480p E2E_DAEMON_DECODE=624x480 E2E_TRANSITION_CYCLES=10 \
PLEX_BASE=http://YOUR-LOCAL-PMS:32400 PLEX_TOKEN=… PLEX_WEB_USER=… \
MISTER_HOST=… \
./tests/hw/e2e/run_cast_picker.sh; echo "true rc=$?"
```

## Frame ledger asserts

Each transition cycle captures ledger at start/end of the continuous-play window
(before stop) via `GET http://$MISTER_HOST:3005/player/telemetry` (preferred) or
`E2E_DAEMON_LOG` tail.

Asserts:
- `residual == frames - presents - drops` (identity)
- residual accounted (`==0` or `==publish_misses` or within `E2E_LEDGER_RESIDUAL_SLACK`, default 2)
- `session` unchanged mid-cycle (daemon self-exit/respawn → FAIL `ledger_session_changed`)
- `lifetime_frames` not regressed

`E2E_REQUIRE_LEDGER=1` (default): unprobed ledger is RED, not a soft pass.
Requires daemon with `/player/telemetry` (this branch) or a live log feed.
