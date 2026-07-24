# Hardware tests

Require a live MiSTer (`MISTER_HOST`, default `192.168.1.183`).

## Phase 1 checklist (manual + automated later)

1. Deploy `Plex.rbf` (`scripts/deploy_plex_core.sh`).
2. CRT/HDMI shows color bars; LED heartbeats.
3. OSD **Content FPS = 24**: moving block advances ~24 times/sec worth of motion (slower than 60).
4. **Content FPS = 60**: block motion fastest.
5. **Audio tone On**: continuous tone, no crackle.
6. Soft reset via OSD: recovers cleanly.
7. Kill any ARM helper mid-run: core keeps presenting (self-contained Phase 1).

Automated closed-loop (Phase 2+) will assert HPS stats for display vs content index ratios.
