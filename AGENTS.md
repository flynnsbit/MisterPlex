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
- **READY_TO_DEPLOY=NO** while exclusive LIVE and/or **DRIFT_CRITICAL** (live SRC ≠ claim freeze without parent **accept-ambiguous**); **NO** until BUILD_OK of a **new** intentional LOCK_OK RBF after HARD_FAIL  
- After BUILD_OK: NEW_RBF ∉ banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,…}`; prefer claim **LOCK_OK**; **ONE** menu only; never thrash **`8832824e`** / **`75da8bb1`** / **`4d6ee356`**; hard expect sticky **`e8 14 xx`**, reject **+0x53**; soft-skip ≠ PASS; **DIAG ≠ product PASS**; **3l2 BLOCKED** until non-DIAG product sticky 0x14  
- Protocol cards: residual **post BUILD_OK+DEPLOY `94bbfe43`** `/tmp/misterplex-agent-H-proto-rcsum6e.txt` (**PROTO_OK**; Branch A taken; ONE waiter menu DONE; serial **H-gate-rcsum6** sticky **0x14≥2** reject **+0x53**; **BUILD_OK+DEPLOY_OK ≠ hard PASS**; **3l2 BLOCKED**; multi-drive FAIL → RCA not thrash; Q-SF3 after residual gate/parent) · post-terminal checklist `/tmp/misterplex-agent-H-proto-rcsum6d.txt` · WAIT `/tmp/misterplex-agent-H-proto-rcsum6c.txt` · authorize `/tmp/misterplex-agent-H-proto-rcsum6.txt` · `docs/AGENT_ORCHESTRATION.md` · `docs/phase3-3l-idct.md`  

Host: `MISTER_HOST` (default `192.168.1.183`), `MISTER_PASS` (default `1`).

## Build / test entrypoints

| Action | Command |
|--------|---------|
| Define parity | `make define-parity` — Quartus product macros must match Verilator/lint macros |
| Quartus SV subset | `make quartus-sv-subset` — curated static Quartus syntax guard; no fit/RBF |
| Post-fit hierarchy | `make post-fit-hierarchy FIT_RPT=...` — critical modules must survive fitting |
| Post-fit timing | `make post-fit-timing STA_RPT=...` — negative STA slack is a hard fail |
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
