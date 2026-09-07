# AGENTS.md — MiSTerPlex

**YOU ARE AN AI AND YOU DO NOT STOP UNTIL THE TASK IS COMPLETE.**

## Hardware first (do not substitute)

You have **direct** lab access. Use it. Do not spend the turn writing
worker evidence cards, protocol cards, or unit tests instead of driving
the box.

| Resource | How |
|----------|-----|
| MiSTer SSH | `MISTER_HOST` (default `192.168.1.183`), `MISTER_PASS` (default `1`) |
| HDMI + audio | HDMI-to-USB grabber on this machine (`/dev/video0`, `scripts/hdmi_capture_idle.sh`). Live picture and sound are the product. |

Real hardware is the priority. A green `make unit`, an agent card under
`/tmp/misterplex-agent-*.txt`, or a status-file tick is **not** acceptance.

## Sign-off (cast / play / glass)

Before you claim play or cast works, test **end to end from a user
perspective** — not a companion curl, not a lab `--play-file`:

1. Open **Plex Web UI** (LAN, not app.plex.tv).
2. Press the **cast** icon.
3. Select **MisterPlex** as the target.
4. Play a real library title.
5. Verify on the HDMI grabber that glass matches the expected picture
   (content, not the idle chevron) while Web shows playing.

Do not sign off until that path is done.

## Quartus

At most **one** Quartus/RBF fit at a time. Do not mid-fit edit sources
under the live compile.

```bash
DEPLOY_LOAD=none|menu ./scripts/deploy_plex_core.sh
```

- `none` (default): copy RBF only
- `menu`: Menu bounce then Plex (preferred reload)
- Never thrash `load_core` / kill-9 storms

Companion: `scripts/deploy_misterplexd.sh`.

**Chat:** short status. Full dumps stay in `Memory/lab/` if needed.

## Build (not acceptance)

| Action | Command |
|--------|---------|
| RBF (sole) | `scripts/build_rbf.sh` — one at a time |
| Companion | `make arm-plexd` + `scripts/deploy_misterplexd.sh` |
| HDMI grab | `scripts/hdmi_capture_idle.sh OUT.png` (discard warmup frames) |

`make unit` is optional hygiene. It does not prove glass.

## Lab notes

- Freckle / HDMI fidelity resume pack: `~/Projects/Memory/lab/AGENTS.md`
  (chevron = two colors; Grid720 ratingKey **143**).
- Durable captures: `$HOME/Projects/MisterPlex/Memory/` (git-ignored).
  Do not run `git clean -xfd` in the primary clone.
- Live Plex tokens are never copied into the store.
- HDMI glass floor (not the product tip): `docs/glass-baseline-pair.md`.

## Durable progress and fresh contexts (required)

Keep this file's fleet progress block and the durable checkpoint current after
meaningful progress, a changed blocker, a completed task, or a hardware/build
ownership transition. Do not leave the only useful state in chat, agent memory,
or the session SQL database.

- The primary checkout's continuation entry point is
  `/home/flynnsbit/Projects/MisterPlex/Memory/lab/fpga-h264-30ff2997/RESUME.md`;
  its `handoff/WORKFLOW.md` defines checkpoint, queue restoration, and
  clean-context startup.
- Permanent cross-interface recovery is the private repository
  `https://github.com/flynnsbit/misterplex-memory`. The local checkpoint is its
  working mirror. The coordinator exports, reviews, commits, and pushes after
  meaningful accepted handoffs and before a context reset; never claim remote
  durability until publication succeeds. If connectivity fails, preserve local
  state and report the remote checkpoint as stale. Never upload live secrets,
  browser data, raw runtime logs, or media without established provenance.
- Each agent must update its own lane handoff before reporting completion or
  pausing, then publish a concise result and next action using
  `python3 /home/flynnsbit/Projects/MisterPlex/Memory/lab/fpga-h264-30ff2997/handoff/checkpoint.py progress --lane NAME --summary "RESULT" --next-action "NEXT"`.
  This serializes updates to the progress block in both primary and worktree
  `AGENTS.md`; agents must not race manual edits to the shared block.
- Before a long-running or state-changing operation, persist its owner, exact
  input/cohort, intended action, output location, and grant. Afterward record
  what actually happened, including failures and unfinished commands.
- The coordinator updates the queue and shared state at each accepted handoff.
  Before a context reset, pause all workers safely and seal a fresh snapshot.
  A draft or stale snapshot is not permission to resume device mutations.
- Resume interrupted work with NEW focused agent contexts from the entry point
  and lane handoffs, not old agent conversations. Retire old contexts first;
  never create duplicate hardware, fit, or source owners.
- Publish status through the durable progress updater and normal task results.
  Contact only explicitly assigned active peers for concrete interface needs;
  never broadcast routine status to retired agents or use them as relays.

Keep this summary short and free of credentials, personal profile names, raw
logs, and configuration secrets. Checkpointing is recovery bookkeeping, never
playback acceptance and never a substitute for returning to the real user path.

<!-- fleet-progress:start -->
### Current fleet progress

Entry point: `/home/flynnsbit/Projects/MisterPlex/Memory/lab/fpga-h264-30ff2997/RESUME.md`.
This is recorded progress, not a live-process or playback acceptance claim.

**Stage:** 240p: agent-owned V12 build readiness, timing tools, DDR/HDMI and lab diagnosis in parallel; source development-branch checkpoint underway..
**Critical path:** Agent-ready exact tooling + private source checkpoint -> explicit V12 fit launch -> real timing results -> clean LAN Web/glass qualification..
**Reset generation:** `context-reset-20260906T1620Z`.
Use the entry point's latest checkpoint and lane notes before resuming.

| Lane | Recorded state | Latest result | Next action |
| --- | --- | --- | --- |
| coherent-fpga-integration | running | V12a793593b complete: one CAVLC leaf;9048 paired blocks/38 pictures/five seeks PASS, original budgets. Source07ff4fa4/inputs37c26991/manifest72d08768. No owned jobs or Quartus. | Parent reviews566-line V12 source and separate reporter binding before physical grant. Timing/area and DDR/HDMI closure unmeasured; V12a01 unused. |
| lab-runtime-integration | running | Actual1 capture/probe/Menu/Web146 complete:384AU EOF/nonce matched.38gaps1.13s/tail1.81s;32-video queue/PCM starvation observed. Trace truncates12.45/17.14s. Healthy8547/all38/no jobs. | Reconcile receipt99d525d2 and causal/retention limits; separately grant any fix or validation. Current18360/18937 remain alive; stopped146 not empty. No more live actions authorized. |
| decoder-feature-completion | paused | PAUSED: approved8KiB P/reference/deblock increment frozen; 31 cases passed, 24 pictures/741888 YUV samples exact. No fit/hardware/24fps acceptance; no running lane commands. | A NEW agent should review release/handoff.json and the four-file patch against approved8KiB before requesting fresh coordinator authorization. |
| ingress-session-completion | paused | PAUSED: isolated 3-file ingress patch packaged; frozen original-PTS, real seek, wrap/reset/backpressure and VCL-limit tests passed. Default 8KiB/E19F retained; 32KiB AU opt-in. Unmerged/unfit; no running commands. | A new agent reviews ingress-session-a10/manifest.json and the three-file patch with the coordinator before any integration. |
| fpga-audio-session-completion | paused | Paused with unchanged 146-file a10 source copy; no audio implementation delta or running commands. Apparent duplicate owner was the same UUID | Assign one fresh audio agent to inspect the concrete DMA/session gap and existing scoped benches |
| video-presentation | running | PAUSED: native-bank lease overlap passes original-PTS PMS139/146 pixel and lifecycle checks. Source-only patch39b2c7ad; display interval unchanged1002936cycles. No active lane workers. | New coordinator reviews presentation-lease.patch against the composed cohort and coordinates ingress ownership predicates before any new grant. |
| decoder-performance | running | Timing tooling v2 READY unchanged: all 16 source/archive pins and Quartus17 API use reviewed. Parent 61-test result retained, not rerun. No source change or netlist/fit invocation. | Coordinator authorizes V12 only; use pinned driver 8166ff88. Tooling owner awaits first actual report; publisher seals updated handoff/progress. |
| sdram-performance | deferred | DEFERRED. Isolated BL4 simulation measured 15.61->62.43 MB/s reads at 142 MHz; refresh-limit caveat preserved. No hardware/canonical changes or running implementation/simulation commands. | Await an explicit coordinator grant to a NEW agent after feature completion. |
| retired-decoder-timing | retired | Retired a09 timing worker is idle with no running commands or implementation delta; its a08-only report is historical | Do not restart this lane; current a10 performance work belongs to agent 90150fc7 |

**Coordinator (2026-09-07T14:39:36.443952+00:00):** Delegated five execution lanes: timing tools, private/dev Git publication, DDR/HDMI timing, live backlog diagnosis, and sole V12 build preparation. Coordinator no longer implements/builds.. Next: Collect tooling readiness and exact private publication, then authorize ONE V12 fit. Git owner also commits/pushes full source checkpoint on dev/fpga-h264 without touching main..

<!-- fleet-progress:end -->

## Stop

The user's named path works on glass (or the user tells you to stop).
Summaries, cards, and BUILD_OK are not stops.
