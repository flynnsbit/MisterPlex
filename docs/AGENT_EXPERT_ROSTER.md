# Expert agent roster (max 10)

Fixed specialist structure for Grok Build multi-agent work on MiSTerPlex.
Parent (orchestrator) is **outside** this list. Concurrent cap: **10 workers**.

Standing brief for every agent: [`Memory/AGENT_BRIEF.md`](../Memory/AGENT_BRIEF.md)  
Playbook: [`agent-fleet-playbook.md`](agent-fleet-playbook.md)  
Case law: [`LESSONS.md`](LESSONS.md)  
Backlog SoT: [`PHASE_BACKLOG.md`](PHASE_BACKLOG.md)

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
    │ exclusive  │      │ adversary  │      │ compose    │
    └────────────┘      └────────────┘      └────────────┘
           │
    non-RBF while fit LIVE
           │
  ┌────────┼────────┬─────────┬─────────┬─────────┐
  ▼        ▼        ▼         ▼         ▼         ▼
w-fpga   w-arm    w-mem    w-clock   w-path    w-osd*
w-build  w-test   (parallel code/sim — isolated worktrees)

* w-osd shares presentation budget with w-mem/w-clock; coordinate via parent.
  If at 10 already, fold OSD into w-fpga rather than adding an 11th worker.
```

---

## The 10 experts

| # | ID | Expert title | Owns (write) | Does **not** own | Worktree | Evidence card |
|---|-----|--------------|--------------|------------------|----------|---------------|
| 1 | **w-fpga** | FPGA RTL | `fpga/Plex_MiSTer/rtl/*` present/frame_store/stream (product path); QIP membership for modules they land | Quartus sole fit; daemon; host ABI constants without w-mem | `MisterPlex-wt-fpga` | `Memory/lab/agents/w-fpga.txt` |
| 2 | **w-arm** | ARM daemon | `arm/misterplexd/*` protocol, idle CPU, SPI client, publish/delete memcpy | RTL; RBF deploy; invent mailbox addrs | `MisterPlex-wt-arm` | `Memory/lab/agents/w-arm.txt` |
| 3 | **w-mem** | Memory / DDR | `ddr_frame_layout*`, BW contract, fabric publish engine, bank/doorbell math, M10K cost **with depth×width class** | Fitting the design; silent QIP-only “land” | `MisterPlex-wt-mem` | `Memory/lab/agents/w-mem.txt` |
| 4 | **w-fit** | FPGA Fit | Sole Quartus; claim freeze; post-fit hierarchy/timing; RBF md5 harvest | Editing sources mid-fit; thrash redeploy; second fit | `MisterPlex-wt-fit` | `Memory/lab/agents/w-fit.txt` + `Memory/lab/quartus/*` |
| 5 | **w-build** | Builds / pre-fit | `make define-parity`, `quartus-sv-subset`, reachability, package scripts, QIP hygiene, Tcl comment class | Device deploy; long feature RTL | `MisterPlex-wt-build` | `Memory/lab/agents/w-build.txt` |
| 6 | **w-test** | Tests | `tests/unit`, `tests/rtl`, harness red/green, skip accounting | Product RTL design; inventing PASS from soft-skip | `MisterPlex-wt-test` | `Memory/lab/agents/w-test.txt` |
| 7 | **rd-duck** | Rubber duck | **Read-only attack** of claims; NACK/ACK cards; instrument bugs | Merges; “fix it” unless parent retasks; device | `MisterPlex-wt-duck` (or no tree) | `Memory/lab/agents/rd-duck.txt` |
| 8 | **w-clock** | Clock / timing | `clk_pix` PLL, SDC/CDC, refresh arithmetic, CEA totals, anti-16 Hz trap | Changing FRAME geometry without w-mem; exclusive fit | `MisterPlex-wt-clock` | `Memory/lab/agents/w-clock.txt` |
| 9 | **w-path** | Path / DMA | PL330 stack, bank options, bitstream feed, T_copy retire path, ARM↔fabric handoff | Full present scaler redesign; fit | `MisterPlex-wt-path` | `Memory/lab/agents/w-path.txt` |
| 10 | **w-integ** | Integration | Compose branch assembly, PR stacking, backlog updates, conflict policy, unit-on-merge | Holding fit exclusive; device without parent | `MisterPlex-wt-integ` | `Memory/lab/agents/w-integ.txt` |

Optional fold-in (not an 11th slot): **OSD / idle chrome** → assign to **w-fpga** or a short-lived task under w-integ.

---

## Exclusive resources

| Resource | Owner | Rule |
|----------|--------|------|
| Quartus sole | **w-fit** only | Parent grants FIT_GO. One log. No mid-fit source edits under live compile. |
| MiSTer device | **Parent** | Token protocol. ONE `DEPLOY_LOAD=menu` after BUILD_OK. Workers propose exact commands only. |
| `origin/main` merge | **Parent** | Workers open PRs / report; parent merges after gates. |

---

## Current programme assignment (720p fabric present + publish)

Base: `origin/main` @ **`ab18a382`** (product 1280×720 geometry landed).  
Device RBF still **stale** until compose fit + ONE menu.

| Expert | Next high-value work |
|--------|----------------------|
| **w-integ** | Stack compose enable branch off `ab18a382`; conflict policy; unit green before fit claim |
| **w-clock** | Compose clk_pix enable recipe; STA risk pre-register (Sweep 136 P4) |
| **w-fpga** | Present/store under L4 or MULTI+PPC2; keep Template path safe when macros off |
| **w-mem** | Product-wire publish engine; M10K depth×width for linebufs; arbiter present > publish |
| **w-path** | DIRECT vs COPY retire of T_copy; PL330 only if measured under one-core |
| **w-arm** | Delete serial memcpy on product path after publish wire; idle budget hold |
| **w-build** | define-parity / QIP / files.qip Tcl; pre-fit reachability under PRODUCT_NO_STUB |
| **w-test** | Compose unit + RTL sim gates; skip accounting |
| **w-fit** | **Idle until** parent FIT_GO on frozen compose candidate; then sole exclusive |
| **rd-duck** | Attack: “compose fit closes timing”; “356 M10K enough”; “fabric COPY free of DDR contention” |

---

## Dispatch template (paste into each spawn)

```text
You are <ID> — <Expert title> on MiSTerPlex.
Read: Memory/AGENT_BRIEF.md, docs/LESSONS.md (relevant L#), docs/AGENT_EXPERT_ROSTER.md (your row).
Worktree: git worktree add ~/Projects/MisterPlex-wt-<id> -b w-<id>-<topic> <base-sha>
Base SHA: <print origin/main or compose tip>
Settled (do NOT re-litigate): full fabric 720p decode dead; PRODUCT_NO_STUB; one effective ARM core; product canvas 1280×720 @ ab18a382.
Task:
  1. ...
  2. ...
Acceptance evidence: named files + `cmd; echo true rc=$?`
Hard rules: no device without parent token; no second Quartus; soft-skip ≠ PASS; BUILD_OK ≠ product PASS; M10K costs state depth×width.
Write evidence to: Memory/lab/agents/<ID>.txt
Return: DONE|BLOCKED, SHAs, true rc, open questions for parent.
```

---

## Bucket file (parent fills each tick)

Path: `/tmp/misterplex-agent-bucket.json` → symlink into `Memory/lab/` via `scripts/relink_lab_evidence.sh`.

```json
{
  "updated": "ISO-8601",
  "base_sha": "ab18a382…",
  "fit_exclusive": "FREE|LIVE:w-fit",
  "device_token": "PARENT|none",
  "target_workers": 6,
  "max_workers": 10,
  "active": [
    {"id": "w-integ", "goal": "…", "worktree": "…"},
    {"id": "rd-duck", "goal": "…", "worktree": "…"}
  ]
}
```

---

## Anti-overlap rules

1. **w-fit** never edits RTL during LIVE fit; **w-fpga/w-mem** never start a second Quartus.
2. **w-mem** owns doorbell/bank numbers; **w-arm** consumes them — no parallel inventing of phys bases.
3. **rd-duck** produces NACK/ACK only until parent promotes a fix task to a write lane.
4. **w-test** may add gates that fail closed; must not weaken gates to go green.
5. Two agents must not share a worktree or branch tip without parent mediation.
