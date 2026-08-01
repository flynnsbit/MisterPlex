# w-plextv suite assessment (honest)

Branch tip at time of writing — see status.txt for SHA.

## REAL assertions (gate can go RED)

| Assertion | How | Decorative? |
|-----------|-----|-------------|
| Exact MiSTerPlex in picker | BEFORE/AFTER body diff; reject MiSTerPlexTest | **Real** — parent rc=0 |
| Companion server host | context.on request /clients | **Real** |
| Companion sort fragility | friendlyName probes + COMPANION_SORT_FRAGILITY log | Diagnostic (PASS still if host matches) |
| Play starts | daemon timeline state=playing + advancing | **Real** |
| Pause freezes time | daemon samples state=paused, drift bound | **Real** (now UI-first) |
| Resume advances | daemon samples | **Real** (UI-first) |
| Seek lands near target | daemon time near offset | **Real** (UI scrubber preferred) |
| Stop → idle | daemon not playing | **Real** (UI stop preferred) |
| N-loop pass==N | per-cycle table; majority ≠ pass | **Real** |
| Daemon pid+exe stable | telemetry getpid + readlink/proc/self/exe | **Real** if daemon deployed |
| Ledger residual | frames-presents-drops | **Real** if telemetry |
| UI clock vs daemon | read Web clock/scrubber vs timeline XML | **Real** (new; can fail ui_timeline_unreadable) |
| TEARDOWN our controller only | browser closed; not global idle | **Real** — parent verified |

## NOT real / out of scope (must not pretend)

| Claim | Status |
|-------|--------|
| Lipsync / A/V offset / av-lock | **NOT asserted** — blind; parent HDMI only |
| Pixel correctness / structure | Parent HDMI instrument only |
| plex.tv provides=player | Refused — proven useless |
| Device conf normalize | Never — user-owned |
| Agent-run E2E as evidence | Forbidden |

## Gaps still weaker than HDMI bar

1. UI timeline selectors may need one parent RED→selector fix (pre-register: if unreadable on real Plex Web chrome, ship better selector from artifact — do not soft-pass).
2. Seek UI scrubber geometry may miss → HTTP fallback is tagged; still asserts land on daemon.
3. Does not compare UI to **glass** chrome (parent's 0:34/6:00) — only UI vs daemon. Glass is HDMI lane.

## Worktrees

- `.worktrees/w-plextv-e2e-fix` branch `w-plextv-cast-picker-e2e-fix2` — **active**
- Older cast-picker worktrees if present are superseded by this tip
