# Multi-agent orchestration (lab)

## Goal
Keep **5–8 worker agents** busy until `docs/PHASE_BACKLOG.md` gates are green.
Parent (top-level) verifies count and **refills the bucket** every tick.

## Every orchestrator tick
1. Read `docs/PHASE_BACKLOG.md` + `/tmp/misterplex-agent-bucket.json`
2. Count open TODO/IN_PROGRESS items
3. Detect Quartus: if `pgrep -f quartus` or docker `*quartus*` → **RBF slot occupied**
4. Spawn workers until **target 6 concurrent** (min 4, max 8):
   - If RBF slot free and FBAR/clean RBF needed → at most **1** build agent
   - All other slots → non-RBF phase work
5. Write `/tmp/misterplex-loop-status.txt` with: time, agent goals spawned, RBF state, next gaps
6. Update PHASE_BACKLOG statuses when workers report DONE

## Safe deploy only
`DEPLOY_LOAD=none|menu ./scripts/deploy_plex_core.sh` — never thrash load_core.

## Non-RBF work pool (always fill from here first when RBF busy)
- P3-3l1 host/RTL prep (no full fit unless sole build)
- P3-DDR product path (misterplexd prefers DDR with new verify)
- Unit tests, package
- P4 scrubber / companion
- P5 soak (no core reload)
- Docs backlog updates
- Commit uncommitted safe deploys scripts

## Stop condition
All PHASE_BACKLOG gates checked + unit green + key HW tests green + package OK.
