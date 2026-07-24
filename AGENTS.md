# AGENTS.md — MiSTerPlex

## Default harness

Use the **multi-agent build harness** for all sustained work in this repo:

- Global rule: `~/.grok/rules/00-multi-agent-build.md`
- Skill: `/multi-agent-build` → `~/.grok/skills/multi-agent-build/SKILL.md`
- Project orchestration: [`docs/AGENT_ORCHESTRATION.md`](docs/AGENT_ORCHESTRATION.md)
- Living backlog (source of truth): [`docs/PHASE_BACKLOG.md`](docs/PHASE_BACKLOG.md)

Parent keeps **~6 workers** filled. **Quartus is the sole exclusive slot.** While fitting, fill only non-RBF work. Evidence-only gates. Never invent BUILD_OK.

## Safe deploy

```bash
DEPLOY_LOAD=none|menu ./scripts/deploy_plex_core.sh
```

- `none` (default): copy RBF only  
- `menu`: Menu bounce then Plex (preferred reload)  
- Never thrash `load_core` / kill-9 storms  

Host: `MISTER_HOST` (default `192.168.1.183`), `MISTER_PASS` (default `1`).

## Build / test entrypoints

| Action | Command |
|--------|---------|
| RBF (sole) | Project Quartus via `misterfpga-dev` / `scripts/build_rbf.sh` — **one at a time** |
| Unit | `make unit` |
| Package | `make package` / `scripts/package_release.sh` |
| FBAR | `tests/hw/test_fbar_fast.sh` |
| Companion deploy | `scripts/deploy_misterplexd.sh` |

## Status files

| Path | Role |
|------|------|
| `/tmp/misterplex-loop-status.txt` | Parent tick |
| `/tmp/misterplex-agent-bucket.json` | Planned workers |
| `/tmp/misterplex-agent-<ID>.txt` | Worker evidence |
| `/tmp/plex_quartus_*.log` | Sole build logs |

## Hard rules (lab)

1. At most **one** Quartus/docker fit.
2. Soft residual skip ≠ hard `res_csum` PASS.
3. Do not mid-fit edit sources under the live compile.
4. Post-BUILD_OK: **one** menu deploy → FBAR reconfirm → hard residual → only then next exclusive (e.g. WIDE Fix-2).
5. Closed eyes experiments stay closed until a **new design** lands (see `docs/p3-wide-rca.md`).

## Key docs

- `docs/phase3-decode.md`, `docs/phase3-3l-idct.md` — decode path  
- `docs/p3-wide-rca.md` — full-width / pillar  
- `docs/crt-lcd-lab-checklist.md` — CRT/LCD lab  
- `docs/release.md` — packaging  

## Stop

All `PHASE_BACKLOG` gates green with evidence + open list clear (or user stops the loop).
