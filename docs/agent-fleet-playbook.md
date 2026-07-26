# Agent fleet playbook

How the parent orchestrator actually runs a fleet of worker agents on this project.
This is the durable structure; `AGENT_ORCHESTRATION.md` holds run-specific lab gates.

---

## 1. The core idea

**One scarce resource, many cheap ones.**

| Resource | Concurrency | Arbitration |
|---|---|---|
| **The MiSTer device** | **1** | Parent-issued *token*. Strictly serial. |
| Quartus on the remote farm | ~5 concurrent fits | Free-for-all. Slots auto-created. |
| Everything else (code, sim, docs, tests) | Unbounded | Isolated git worktrees. |

Almost every scheduling mistake comes from treating the device like the farm, or the
farm like the device. The device is the bottleneck, so **the parent's main job is to
keep the device busy with the highest-value validation while everyone else does
off-device work.**

Corollary: when a worker is blocked on the device, do not let it idle — give it
simulation, RTL, docs, or test work instead.

---

## 2. Worker isolation

Every worker gets its own git worktree and its own branch:

```bash
git worktree add /home/shawn/Projects/mp-wt-<id> -b feat/<id> <base>
```

Rules:
- A worker **never** touches a sibling worktree.
- A worker **never** merges to `main`. It reports; the **parent** merges.
- Branch off the branch you are extending, not always `main`
  (e.g. RTL work extending the SDRAM branch bases off `feat/b2`).

**Watch for base drift.** Long-lived branches silently fall behind. The parent checks
mergeability *before* the work is finished, not after:

```bash
git merge-tree --write-tree main feat/<id>   # CONFLICTS => order a rebase now
```

This caught two branches whose built artifacts predated a major merge — their binaries
were stale even though their source compiled.

---

## 3. The token protocol (device access)

1. Parent grants explicitly: *"You have the deploy token, starting now."*
2. Worker does **one** deploy, no `load_core` thrash.
3. Worker **proves the new bitstream is live** before believing any measurement —
   a wedged `Main` will let the SD card update and md5-verify while the FPGA keeps
   running the **old** bitstream. Prove liveness via a mailbox, not a checksum.
4. Worker time-boxes itself (20–30 min), then says **"token released"** and states
   the exact device state it left behind.
5. On any failure: **roll back to the last known-good bitstream immediately.**
   Debug off-device. Never leave a broken picture on screen.

Workers may **not** take the device unasked. This has been violated, and it silently
contaminated another worker's concurrent measurements.

---

## 4. Anatomy of a worker prompt

Sub-agents are **stateless**. Brevity is the enemy. Every dispatch contains:

1. **Worker ID and todo id** — so it can update SQL itself.
2. **Project context** — what this repo is, in two or three sentences.
3. **The user's actual words** where relevant. Paraphrase loses intent.
4. **Worktree setup command**, with the correct base branch.
5. **Hard-won background** — prior measurements, dead ends, and *why* they are dead.
   This is the highest-value section. It stops workers re-deriving known facts and
   re-walking disproven paths.
6. **The task**, numbered, with the acceptance evidence named for each item.
7. **Protected invariants** — things that must survive verbatim, and why they matter
   (ideally "the user personally reported this bug"). Name the file and the symbols.
8. **Arithmetic that should guide judgement** — give them the budget numbers so they
   can tell a structural bug from a capacity limit.
9. **Hard rules** — device access, no merging, evidence standards, no secrets.
10. **Completion contract** — update the todo, and return a specific summary.

### The "negative results" rule

Tell workers what has already been **disproven**, not just what is known. On this
project three plausible optimisations were killed by measurement. Every worker prompt
carries that list, so nobody spends a window re-testing a dead hypothesis.

### The "prove it fails" rule

Ask for negative test cases explicitly. A suite that only proves the happy path does
not detect regressions. For a detector, require evidence that it **fails** on planted
faults — a guard was accepted here only after it was demonstrated red on a planted
violation and green on a clean tree.

---

## 5. Evidence standards

- **Never claim `BUILD_OK` / `PASS` without the log.** Quote real numbers.
- **Soft skip ≠ pass.** A test that did not run is `UNVERIFIED`, never green.
- **A measurement beats an argument.** Multiple confident plans died to a 2-minute test.
- **Cross-corroborate.** The strongest diagnosis on this project had three independent
  signals agreeing: a hardware counter, a simulation reproducing the exact mismatch
  count, and the user's naked-eye description. Any one alone would have been arguable.
- **Make faults observable in hardware.** A dedicated underrun counter published to a
  mailbox caught a corruption bug on its first outing that would otherwise have shipped
  as an intermittent "video glitch".

---

## 6. Parent tick loop

Every ~2 minutes:

```bash
for w in <ids>; do
  d=~/Projects/mp-wt-$w
  echo "$w: $(git -C $d log --oneline origin/main..HEAD | wc -l)c \
             $(git -C $d status --porcelain | wc -l)d"
done
```

Commits + dirty-file counts are a cheap liveness proxy that costs no agent context.

Each tick the parent asks:
1. Is the **device** busy with the most valuable thing available?
2. Is anyone **wedged**? (long elapsed + zero commits + no artifacts)
3. Has anyone's **base drifted** under them?
4. Is there idle capacity to refill?

### Detecting a wedged worker

Elapsed time alone is not evidence. Check for **artifacts**: commits, changed files,
expected side effects. One worker held the device 71 minutes; the tell was that the
config file it was supposed to be editing had not been modified in two days.

**Known limitation:** there is no tool to kill an agent — `stop_bash` does not work on
them. And a worker stuck in its *first* turn can never receive queued messages, so it
is unreachable. Retire it by reclaiming its resources and spawning a replacement with a
corrected prompt.

---

## 7. Parent responsibilities that do not delegate

The parent owns the things that need a whole-repo view:

- **Merging**, and running the pre-push discipline: unit tests, secret scan,
  strip-coauthor script.
- **Reviewing the outgoing diff** — a hardcoded LAN IP, and later a stale hardcoded
  address, were both caught here and nowhere else.
- **Closing gaps by reasoning** instead of spending a device window. One "UNVERIFIED"
  hardware gate was resolved by observing the relevant file was byte-identical between
  branches, so the behaviour could not have regressed.
- **Converting repeated human review failures into automation.** When the same class of
  mistake escapes review three times, stop reviewing and write the test.

---

## 8. Handling a failed worker result

A failure that follows protocol is a **good** outcome. Say so — it reinforces the
behaviour you want.

Then redirect with analysis rather than "try again":

1. **Do the arithmetic** and tell them what the numbers rule out.
2. **Name the hypotheses**, ranked, with the reasoning for the ranking.
3. **Change the method**, not just the parameters. The decisive instruction on this
   project was *"get off the hardware and into simulation — the next thing you produce
   should be a passing testbench, not another bitstream."* It found the root cause in
   one turn after hardware debugging had failed repeatedly.
4. **Forbid the sweep-more-parameters reflex** when the numbers say the design is
   structurally broken rather than marginal.

---

## 9. Anti-patterns

| Anti-pattern | Why it bites |
|---|---|
| Serializing work that does not need the device | The farm sat at 3% utilisation while fits were queued one at a time. |
| Adding buffer to fix starvation | If the fetch is structurally broken, more buffer just delays the same failure identically. |
| Trusting a checksum as liveness | A wedged `Main` updates and verifies the file while the FPGA runs the old image. |
| Assuming a long-running agent is working | Check artifacts, not elapsed time. |
| Reviewing for secrets by hand | Escaped three times, including into a published release. |
| Letting a worker self-merge | Loses the whole-repo view where cross-cutting bugs are caught. |
