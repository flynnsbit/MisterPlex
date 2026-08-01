# w-plextv suite assessment (honest) — definition-of-done half

Branch tip: see `status.txt` for SHA. Agent runs are **not** evidence; parent runs score.

## REAL assertions (gate can go RED)

| Assertion | How | Real? |
|-----------|-----|-------|
| Exact MiSTerPlex in picker | BEFORE/AFTER body diff; reject `MiSTerPlexTest` | **Real** (parent @ older SHA) |
| Companion server host | `context.on('request')` `/clients` | **Real** |
| Companion sort fragility | friendlyName probes + log | Diagnostic (still PASS if host matches) |
| Play starts | daemon timeline `playing` + advancing | **Real** |
| Pause / resume / seek / stop | UI-first; effect on daemon time | **Real** (parent N=1; tip wants N=10) |
| N-loop pass==N | per-cycle taxonomy; majority ≠ pass | **Real code**; parent evidence pending on tip |
| Daemon pid+exe stable | telemetry `getpid` + `readlink(/proc/self/exe)` | **Real** if daemon deployed |
| Ledger residual / session | telemetry | **Real** if telemetry |
| UI clock vs daemon | `ui_timeline.js` skew/pct | **Real** (can `ui_timeline_unreadable`) |
| TEARDOWN our controller only | browser closed; not global idle | **Real** — parent verified |
| PMS unreachable → not PASS | `UNVERIFIED` **rc=2** | **Real** (prove_red_paths P2) |
| Daemon down → FAIL | preflight `daemon_unreachable` rc=1 | **Real** (prove_red_paths P1 + suite) |
| Wallclock timeline series | `PLEX_TIMELINE_SAMPLE` + jsonl | **Emitted** for parent HDMI join |

## NOT covered / must not pretend

| Claim | Status |
|-------|--------|
| Lipsync / A/V offset / av-lock | **NOT asserted** — blind; parent HDMI only |
| Pixel / structure / 0.70% frame loss stage split | Parent HDMI (+ series may help split PMS vs device) |
| Glass chrome vs UI clock | Only UI↔daemon; glass is HDMI lane |
| plex.tv `provides=player` | Refused — proven useless |
| Device conf normalize | Never — user-owned |
| Agent-run E2E as evidence | Forbidden |
| SHIELD / remote PMS | Refused (`refusing_non_local_pms`) |

## Gap list vs user definition of done (W6)

| User flow | Covered? |
|-----------|----------|
| Discover MiSTer as cast target in Web UI | **Yes** |
| Select media + play | **Yes** |
| Pause / resume / seek / stop from Web UI | **Yes** (UI-first; HTTP fallback tagged) |
| Session state + position Plex reports | **Yes** (daemon timeline + UI clock) |
| Target connected | **Partial** — picker + companion + playing samples; no separate “connected” chrome assert |
| N-loop flakiness | **Yes** default N=10 |
| PID stability across run | **Yes** when telemetry has pid/exe |
| RED when daemon down | **Yes** (default require) |
| No blind green if PMS down | **Yes** rc=2 UNVERIFIED |
| Correlate timeline to HDMI wallclock | **Yes** series file — parent joins |
| Attribute 0.70% loss to PMS vs device | **Not claimed** — series is an input only |
| Real non-fixture library titles | **Weak** — often empty; fails loud when required |

## Worktree

- Active: `.worktrees/w-plextv-e2e-fix` · `w-plextv-cast-picker-e2e-fix2`
