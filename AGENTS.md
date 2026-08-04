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

Keep writing to the `/tmp` paths below — they are unchanged. Each one is now a
**symlink into a permanent store outside the worktree**, so evidence survives a
reboot. `/tmp` being cleared has already destroyed a session's history once.

| Path (write here) | Role |
|------|------|
| `/tmp/misterplex-loop-status.txt` | Parent tick |
| `/tmp/misterplex-agent-bucket.json` | Planned workers |
| `/tmp/misterplex-agent-<ID>.txt` | Worker evidence |
| `/tmp/plex_quartus_*.log` | Sole build logs |

## Who tests

**The parent orchestrator performs ALL hardware testing itself.** The parent owns the
HDMI-to-USB capture (`/dev/video0`, MacroSilicon `534d:2109`) and full Plex Web UI access,
so it is the only role that can observe what the MiSTer actually renders and what Plex
actually sees.

- **Agents build and code. Agents do not test on the device.** No agent drives casts,
  captures HDMI, bounces the daemon, or mutates `/media/fat/misterplex/`.
- Agents produce a change plus the exact command the parent should run to verify it.
- The parent runs it, captures the artifact (frame, log, exit code), and reports the
  result back into the thread and to the user.
- Device-observed claims are only valid when the **parent** captured them. An agent
  asserting a hardware result is a rule-0 violation.

Capture the idle/playback screen with:

```bash
scripts/hdmi_capture_idle.sh /tmp/live.png
```

**Never use a bare `ffmpeg -frames:v 1`.** The MJPEG grabber needs ~15 frames to
lock, so a single-frame grab returns a **false black** no matter what the MiSTer is
really showing — that recipe has already produced false REDs in this lab. The helper
discards the warm-up, retries, and prints `MEAN/STD/ORANGE_PX/ACTIVE` so a frame can
be scored rather than eyeballed. It exits `GRABBER_NOT_READY` (rc=1) instead of
handing back a black frame that could be misread as a device failure.

A genuine sustained black (helper retries exhausted, and the stable pair still
renders on the *same* capture chain) is a real result: it is the mixed core/daemon
failure where the core never frees a DDR bank.

`/dev/video0` is exclusive — a desktop app (OBS, `xdg-open`, nautilus preview) holding it
makes capture fail with `Device or resource busy`. Check with `fuser -v /dev/video0`.

Permanent store: `$HOME/Projects/MisterPlex/Memory/` — `lab/` holds the live
orchestration evidence (`parent/`, `agents/`, `status/`, `quartus/`), and
`tmp-rescue-*/` holds artifacts recovered from `/tmp`. Read
`lab/parent/misterplex-parent-720p-decode-verdict.txt` first — it is the
authoritative project record. `Memory/README.md` indexes the whole store.

After a reboot, or any time `/tmp` is cleared, restore the links:

```bash
scripts/relink_lab_evidence.sh
```

`/tmp` is **tmpfs**: it is guaranteed to be erased on reboot, so nothing of value
may live there. `Memory/` is git-ignored (`.gitignore` + `.git/info/exclude`)
because it holds the lab PMS address and device captures.

**Known hazard:** git-ignored files inside a repo are exactly what `git clean -xfd`
deletes. Two things contain that risk, and neither removes it — do not run
`git clean -xfd` in the primary clone:

1. `Memory/` lives in the **primary clone** (`~/Projects/MisterPlex`), while all
   build/test work happens in separate worktrees (`MisterPlex-wt-*`), so a clean
   during a build does not reach it.
2. No script in this repo runs `git clean`; the risk is manual only.

Live Plex tokens (`/tmp/.tok*`) are **never** copied into the store, and token
values are redacted from every text file that is.

## Hard rules (lab)

0. **NO GUESSING — this rule outranks every other rule here.** Never state a cause,
   diagnosis, or status that is not backed by **quoted code, a captured exit code, a
   measured artifact, or a screenshot**. If you do not have that evidence, the only
   permitted answer is *"unknown — here is the check that would settle it."*
   A plausible-sounding mechanism is **not** a finding. Applies to the parent
   orchestrator and to every agent, without exception.
   - Attributing a failing test to "contention", "flakiness", or "environment"
     **without proving it** is a guess. Re-run it and read the actual error.
   - Distinguish *"the log does not contain X"* (evidence) from *"X did not happen"*
     (inference). Say which one you have.
   - Capture exit codes **directly** (`cmd; echo "true rc=$?"`), never through a pipe.
   - A soft-skip (exit 77) is **not** a pass. `UNSCORED` is not a pass.
   - **Pre-register** predictions before measuring, and publish misses.
1. At most **one** Quartus/docker fit.
2. Soft residual skip ≠ hard `res_csum` PASS.
3. Do not mid-fit edit sources under the live compile.
4. Post-BUILD_OK: **one** menu deploy → FBAR reconfirm → hard residual → only then next exclusive (e.g. WIDE Fix-2).
5. Closed eyes experiments stay closed until a **new design** lands (see `docs/p3-wide-rca.md`).

### Guessing incidents on record (why rule 0 exists)

| Guess | Reality |
|---|---|
| A RED `make unit` was "transient contention" | Real failure: a lane had committed a hardcoded lab IP, tripping `test_no_private_data` |
| `PLEX_TOKEN` absent, so playback blocked on the user | Token was present the whole time |
| The ARM profile asset was destroyed by `make clean` | Intact in a sibling worktree |
| "93%" idle score meant 93% complete | It was `G-IDLE2c`, a *defect* similarity metric |
| `PRESENT=fb0` was the right value from `package_release.sh` | `initPresent()` skips `fpga_.open()` unless `PRESENT=fpga\|both`, so the DDR frame store was never repainted and the idle screen froze |

## Tangible progress, anti-ceremony, honest credit

The purpose of this project is **working, deployable software** delivered accretively in
the shortest time compatible with correctness, performance, reliability and innovation.
Process exists to serve that outcome; **it must never become the product.**

- **No process porn.** Certificates, ledgers, dashboards, meta-reports and process
  documents are not progress. A process artifact may exist **only** when it is a hard gate
  for a **named** feature or capability. A conformance validator or required release
  evidence qualifies; self-referential paperwork does not. Choosing process artifacts
  because they are easy and low-risk is **reward hacking** and is treated as such.
- **Feature-first ratio.** The overwhelming majority of open work must deliver **runnable
  behaviour** — code, schemas and contracts an end user or consuming agent can exercise.
  Process/ops items are capped at ~5% of open work and each must **name the feature it
  gates**. A process item that gates nothing does not get created.
- **Honesty is absolute.** Never fake a test, present a fixture or mock as live proof,
  weaken an assertion to make it pass, hard-code a success path, or close work that is not
  done. A false close is reopened with an incident comment on the record.
- **Refusal is not delivery.** A correctly typed refusal beats a fabricated result, and is
  worth far less than the real capability. Implementing **only** the refusal path earns
  partial credit at most and **never closes a feature item**. Full credit requires the
  positive capability implemented for real, tested and verified. Mark refusal-only states
  explicitly with a follow-up item so they read as unfinished, never as shipped.

These bind human-directed sessions and agent swarms alike, and must be encoded into the
**acceptance criteria of the work items themselves**.

### Named reward-hacking patterns (all forbidden)

| # | Pattern | What it looks like here |
|---|---|---|
| 1 | **Gate self-weakening** | Editing validator/conformance code so a failing check passes. Conformance code is a single-owner lane with reviewer sign-off. |
| 2 | **Proof-class inflation** | Fixtures, retained captures, mocked endpoints or hand-inserted rows presented as live proof. Live proof needs runtime-selected subjects, recorded selection seeds, receipts chained to real manifests, and fresh-process readback. |
| 3 | **Golden regeneration reflex** | Regenerating goldens to match broken output instead of fixing the output. Golden changes require a `GOLDEN-CHANGE` commit note and semantic diff review. |
| 4 | **Commit-stream pumping** | Trivial or artificially split commits; `todo!()`/`unimplemented!()` scaffolds that merely compile. Placeholder macros are **banned** in committed code. Every commit names its work item and touched scope. |
| 5 | **Tautological tests** | Tests asserting the code does whatever the code does, or omitting negative cases. Every feature pre-specifies its behavioural assertions **including at least one negative case** a naive wrong implementation would fail. |
| 6 | **Easy-bead cherry-picking** | Claiming low-risk work while articulation-point work starves. Claim the highest-priority ready item. |
| 7 | **Close-pump abuse** | Closing items to flood the ready pool. **Only the orchestrator closes.** |
| 8 | **Scope-splitting** | Splitting one unit into types/impl/tests to harvest multiple credits. Code and its tests ship in the same item. |
| 9 | **Spec-editing as progress** | Weakening a plan, spec or frozen decision instead of implementing it. Plan edits never close feature work. |
| 10 | **Conformance metastasis** | Speculative checks/matrices/reports added because they are safe. A new check must cite an **observed defect class** or a named release gate. |
| 11 | **Dependency smuggling** | Vendoring or shimming around banned dependencies to "make progress". |
| 12 | **Demo-path hardcoding** | Special-casing pilot subjects so the happy path passes. Test subjects must differ from development fixtures. |

## Key docs

- **[`docs/LESSONS.md`](docs/LESSONS.md) — accumulated case law under rule 0. Read this
  before reasoning about a build, a gate, a device symptom, or an area budget. Every rule
  in it was paid for with a real wrong conclusion in this project.**
- `docs/phase3-decode.md`, `docs/phase3-3l-idct.md` — decode path  
- `docs/p3-wide-rca.md` — full-width / pillar  
- `docs/crt-lcd-lab-checklist.md` — CRT/LCD lab  
- `docs/release.md` — packaging  

## Stop

All `PHASE_BACKLOG` gates green with evidence + open list clear (or user stops the loop).
