# Expert agent roster (max 10)

Fixed specialist structure for Grok Build multi-agent work on MiSTerPlex.
Parent (orchestrator) is **outside** this list. Concurrent cap: **10 workers**.

**Product mandate:** move as much of PMS playback as possible **off the ARM onto the
FPGA** on the DE10-Nano, using **DDR, BRAM/M10K, SDRAM, and SD card** where each
earns its keep. Endstate: solid **240p + 480p + ≥720p** streaming from Plex Media Server.

| Tier | Programme status |
|------|------------------|
| 240p | **Complete / lab-tested** product path (tear-free present + cast) |
| 480p | **Complete / lab-tested** product path (same stack, eyes-on + gates) |
| 720p | **Active** — geometry on `main`; fabric present/publish/offload to prove on device |

Standing brief: product clone `Memory/START_HERE.md` + `Memory/AGENT_BRIEF.md`  
Rubber duck: `Memory/lab/agents/RD_DUCK_CHARTER.md` (**clean context**)  
Playbook: [`agent-fleet-playbook.md`](agent-fleet-playbook.md) · Case law: [`LESSONS.md`](LESSONS.md)  
Backlog: [`PHASE_BACKLOG.md`](PHASE_BACKLOG.md)

---

## Fleet diagram

```text
                    ┌─────────────────────┐
                    │  PARENT (you)       │
                    │  merge · device ·   │
                    │  fit token · backlog│
                    └──────────┬──────────┘
           ┌───────────────────┼───────────────────┐
           ▼                   ▼                   ▼
    ┌────────────┐      ┌────────────┐      ┌────────────┐
    │ w-fit  (1) │      │ rd-duck    │      │ w-integ    │
    │ exclusive  │      │ CLEAN CTX  │      │ compose    │
    └────────────┘      │ no assume  │      └────────────┘
           │            └────────────┘
    non-RBF while fit LIVE
           │
  ┌────────┼────────┬─────────┬─────────┬─────────┐
  ▼        ▼        ▼         ▼         ▼         ▼
w-fpga   w-arm    w-mem    w-clock   w-path    w-build
w-test   (parallel — isolated worktrees; real RTL/offload first)
```

---

## The 10 experts

| # | ID | Expert title | Owns (write) | Does **not** own | Worktree | Evidence card |
|---|-----|--------------|--------------|------------------|----------|---------------|
| 1 | **w-fpga** | FPGA RTL | Real SystemVerilog for present/frame_store/stream/offload modules; QIP + **instantiation** | Quartus sole; inventing phys map without w-mem | `MisterPlex-wt-fpga` | `Memory/lab/agents/w-fpga.txt` |
| 2 | **w-arm** | ARM daemon | `misterplexd` — shrink CPU path; protocol; SPI; delete work fabric takes | Fake “offload” that still copies on ARM | `MisterPlex-wt-arm` | `Memory/lab/agents/w-arm.txt` |
| 3 | **w-mem** | Memory fabric | DDR banks/doorbells, BW, BRAM/M10K budgets (**depth×width**), SDRAM trade-offs, publish engine | Fit exclusive; QIP-only land | `MisterPlex-wt-mem` | `Memory/lab/agents/w-mem.txt` |
| 4 | **w-fit** | FPGA Fit | Sole Quartus; claim freeze; post-fit hierarchy/timing; RBF md5 | Mid-fit source edit; thrash redeploy | `MisterPlex-wt-fit` | `Memory/lab/agents/w-fit.txt` |
| 5 | **w-build** | Builds | define-parity, quartus-sv-subset, reachability, package, SD-card release layout | Device; feature RTL | `MisterPlex-wt-build` | `Memory/lab/agents/w-build.txt` |
| 6 | **w-test** | Tests | Unit/RTL sim **with red twins**; no soft-skip green | Weakening gates to pass | `MisterPlex-wt-test` | `Memory/lab/agents/w-test.txt` |
| 7 | **rd-duck** | Rubber duck | Clean-context ACK/NACK only — see charter | Implementation; fleet memory; fake tests | **no shared chat**; optional empty wt | `Memory/lab/agents/rd-duck.txt` |
| 8 | **w-clock** | Clock / timing | clk_pix PLL, SDC/CDC, refresh; anti-16 Hz trap | Geometry ownership without w-mem | `MisterPlex-wt-clock` | `Memory/lab/agents/w-clock.txt` |
| 9 | **w-path** | Path / DMA | PL330, fabric handoff, retire ARM T_copy | Present scaler redesign; fit | `MisterPlex-wt-path` | `Memory/lab/agents/w-path.txt` |
| 10 | **w-integ** | Integration | Compose land, PR stack, backlog truth | Device without parent; fit exclusive | `MisterPlex-wt-integ` | `Memory/lab/agents/w-integ.txt` |

---

## Rubber duck — clean context protocol (parent must obey)

1. **New subagent every review** (or stripped prompt with zero fleet history).
2. Attach **only**: the claim (verbatim) + file paths + SHAs + any log excerpts that are primary sources.
3. Instruct: read `Memory/lab/agents/RD_DUCK_CHARTER.md` and produce **only** the VERDICT card.
4. Do **not** paste “we already proved X” without the measurement file.
5. On NACK: parent retasks a **write** expert with the REQUIRED_NEXT measurement — not “try harder.”

rd-duck is the immune system against **assumed green** and **tests that don’t run**.

---

## Exclusive resources

| Resource | Owner | Rule |
|----------|--------|------|
| Quartus sole | **w-fit** | Parent FIT_GO only |
| MiSTer device | **Parent** | Token; ONE menu after BUILD_OK; SD card paths under `/media/fat/` |
| `origin/main` | **Parent** | Workers PR; parent merges |

**Memory map tools (all experts may reason; w-mem owns numbers):** DDR frame banks, doorbells, BRAM linebufs, optional SDRAM, SD for RBF/daemon/conf.

---

## Current programme (after geometry land)

Base: `origin/main` (product **1280×720** geometry + roster docs).  
Device RBF may still be **stale** — no device claims until ONE new LOCK_OK deploy.

| Expert | Focus |
|--------|--------|
| **w-fpga / w-mem / w-clock / w-path** | Real fabric present + publish + clocks; offload ARM copy |
| **w-arm** | Thin daemon once fabric owns pixels path |
| **w-build / w-test** | Honest gates; red before green |
| **w-fit** | Idle until compose freeze + FIT_GO |
| **w-integ** | One land line; no parallel main stories |
| **rd-duck** | Clean-context attack of every BUILD_OK / 720p budget / offload claim |

---

## Dispatch templates

### Write expert (w-fpga, w-mem, …)

```text
You are <ID> — <title>. Mandate: real FPGA offload for PMS 240p/480p/720p.
Read Memory/START_HERE.md + Memory/AGENT_BRIEF.md + your row in docs/AGENT_EXPERT_ROSTER.md.
Worktree: ~/Projects/MisterPlex-wt-<id> from base <sha>. Never /tmp.
Settled: 240p/480p product present tested; full fabric 720p decode dead; one ARM core effective.
Task: <numbered>. Evidence: true rc + paths. No soft-skip PASS.
Write Memory/lab/agents/<ID>.txt
```

### rd-duck only

```text
You are rd-duck. CLEAN CONTEXT. No fleet history. No assumptions.
Read only: Memory/lab/agents/RD_DUCK_CHARTER.md and the following claim package:
---
CLAIM: …
SHA: …
PATHS: …
EXCERPTS: …
---
Open those paths yourself. Run only checks you need. Output VERDICT card only.
Do not write product code. Do not invent tests or PASS.
```

---

## Bucket

See [`agent-bucket.example.json`](agent-bucket.example.json). Live: `/tmp/misterplex-agent-bucket.json` → Memory via `scripts/relink_lab_evidence.sh`.
