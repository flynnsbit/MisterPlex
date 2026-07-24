# Multi-agent orchestration (lab)

**Default harness (all projects):** `~/.grok/rules/00-multi-agent-build.md` + skill `/multi-agent-build`  
(`~/.grok/skills/multi-agent-build/SKILL.md`). Repo entry: root `AGENTS.md`.

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

## Post–R-csum1 hard residual gate (status)

**R-csum1 BUILD_OK** md5 **`dabdaeb0`** (full `dabdaeb0c5ae708c4fdbba388ba275b6`). Sources committed **`7bee0a6`**. Quartus **not LIVE**.

**H-deploy-rcsum1 / H-rcsum-gate DONE (2026-07-24):**
- Promote + **one** `DEPLOY_LOAD=menu` → lab md5 match **PASS**
- FBAR **PASS** (m1=82.9 m2=94.4)
- res_dc=-24 **PASS** (raw[12]=0xE8 stable)
- **res_csum HARD FAIL** — raw[13] unstable (139/222/49) ≠ 0x14; soft-skip EXIT=0 **≠ hard PASS**
- Park bars **PASS**
- Report: `/tmp/misterplex-agent-H-rcsum-gate.txt`, `/tmp/misterplex-agent-H-deploy-rcsum1.txt`

**Do not invent hard PASS.** Do **not** thrash-redeploy **`dabdaeb0`** expecting green. Next residual work = RCA branch **a** (status path / preserve / multi-drive) before any new sole rebuild. 3.3l-2 paint stays **BLOCKED**.

Tools: `tests/parse_res_csum_status.py` (A-csum-host2); lab `push_frame --status`/`--raw` (A-arm-csum). Full protocol (historical + contingency): `docs/phase3-3l-idct.md` § *Post–R-csum1 sole-deploy + hard-gate protocol*.

## Non-RBF work pool (always fill from here first when RBF busy)
- P3-3l1 residual RCA prep (no full fit unless sole build + authorized)
- P3-WIDE Fix-2 RTL when authorized (colorbars only; design READY)
- P3-DDR product path (misterplexd prefers DDR with new verify)
- Unit tests, package
- P4 scrubber / companion
- P5 soak (no core reload)
- Docs backlog updates
- Commit uncommitted safe deploys scripts

## Stop condition
All PHASE_BACKLOG gates checked + unit green + key HW tests green + package OK.
