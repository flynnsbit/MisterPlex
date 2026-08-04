# Lessons learned — measurement discipline

Every rule below was paid for with a real wrong conclusion in this project. They are
recorded so the same mistake is not made twice. `AGENTS.md` rule 0 (**no guessing**)
is the parent rule; this file is the accumulated case law under it.

Read this before reasoning about a build, a gate, a device symptom, or an area budget.

---

## 1. Verify the artifact you are actually holding

**L1 — Pair by release, not by file date.**
A release core was tested against a *development* daemon, showed bars, and was written off.
Testing a release core against a mismatched daemon proves nothing about either. The matched
pair later played video fine. Always deploy and test core + daemon as a matched set.
*(Miss #22)*

**L2 — Measure the tree you are claiming about.**
A claim that five 720p present modules had landed on main was broadcast to nine agents as
fact. It came from measuring the wrong worktree. Before any claim about `main`, resolve the
worktree path and print the HEAD you actually measured.
*(Miss #19)*

**L3 — "It passes on my branch" is not evidence about main.**
Gate results are properties of a specific tree at a specific commit. Re-run on the target
tree; do not carry a result across trees.

**L4 — One grep in one file does not prove absence.**
A symbol was declared unconfirmed after grepping a single file; the real definition was in a
different path. Absence requires searching the whole relevant surface, and — for RTL —
checking *instantiation*, not just file membership.
*(Miss #7)*

---

## 2. Exit codes and gate output

**L5 — `rc=0` is not PASS if the run contains skips.**
A `make unit` rc=0 was read as PASS while the run contained `SKIP-NOT-PASS` markers. Read the
skip summary, never just the exit code.
*(Miss #20)*

**L6 — Exit 77 is a soft-skip, not a pass.** `UNSCORED` is not a pass either.

**L7 — Capture exit codes directly, never through a pipe.**
Use `cmd > out.log 2>&1; echo "true rc=$?"`. A pipe reports the exit code of the last stage.

**L8 — A test that has never gone RED proves nothing.**
Show every new assertion RED against the unfixed source and GREEN after, both with captured
exit codes. Include at least one negative case a naive wrong implementation would fail.

**L9 — Agreement of values is not correctness of selection.**
Two constants matching does not mean the right one is being used. Check what the code
actually reads at runtime.

---

## 3. FPGA build reality

**L10 — A file absent from `files.qip` is invisible to Quartus.**
The entire H.264 decoder hierarchy was absent from the build manifest while appearing present
in the source tree. `stream_path.sv` instantiated a diagnostic painter in its place.

**L11 — QIP membership does not mean the module is in the bitstream.**
`h264_cavlc_residual` was in `files.qip`, but its only instantiation lived in a file that was
*not*. Quartus compiled it and pruned it: zero logic in the RBF. **Reachability**, not
membership, is the property that matters. This is what the pre-fit reachability gate exists
to catch.

**L12 — Do not plan area recovery against unmeasured assumptions.**
"Delete CABAC and recover area" was stated as fact to several lanes and was worth **zero** —
measurement against the fitted hierarchy showed ALM 0, M10K 0. Deleting something that
contributes nothing frees nothing. Measure before promising.
*(Miss #17)*

**L13 — Timing measured on logic you intend to delete is not your timing.**
A route was killed by an Fmax whose critical path ran through a stub scheduled for removal.
Check what the critical path actually traverses before accepting a timing verdict.
*(Miss #18)*

**L14 — Cycle budgets for a pipeline that is not in the build describe nothing.**
Confirm the module is reachable in the fit before trusting any performance number about it.

---

## 4. Hardware measurement

**L15 — Never thrash `load_core`.**
Reloading a core underneath a running daemon invalidates its FPGA handles and yields a black
screen that looks exactly like a dead bitstream. Correct harness: **load core → bounce daemon
→ capture**. A control reload of a known-good core is what exposed this artifact.
*(Miss #21)*

**L16 — Never use a bare `ffmpeg -frames:v 1`.**
The MJPEG grabber needs ~15 frames to lock, so a single-frame grab returns a **false black**.
Use `scripts/hdmi_capture_idle.sh`, which discards warm-up, retries, and prints scoreable
metrics.

**L17 — Verify the system is in the state you think before sampling.**
An "ARM saturated at idle" reading was taken while a transcode from an earlier cast was still
running. Re-measured with the process count verified *in-sample*, the finding held — but the
first sample was invalid. Assert the precondition inside the sample, not before it.

**L18 — Judge a frame by viewing it, not by `MEAN` alone.**

**L19 — Playback stop is delayed.** `POST .../playback/stop` returns 200 while ffmpeg persists
several seconds. That is not a leak.

**L20 — Distinguish "the log does not contain X" (evidence) from "X did not happen"
(inference).** Say which one you have.

---

**L26 — Always capture the UNCONTENDED baseline before declaring a performance wall.**
Native 720p decode measured `speed=0.939×` and was declared arithmetically dead. The
measurement had been taken with `misterplexd` running. With the daemon stopped and
everything else identical, the same asset and command gave **`1.31×` (32 fps, idle
0.0% → 49.4%)** — a 43% speedup that had been sitting invisible behind background load.
A contended measurement is an upper bound on the *system*, never on the *capability*.
When a measurement is blocked (flaky SSH, dropped session), mark it **UNMEASURED** and
come back for it — do not let a contended number quietly become the accepted ceiling.

**L27 — Run long device measurements detached (`nohup setsid …`), writing to a file.**
The clean baseline above went uncaptured for days because SSH dropped mid-run on flaky
WiFi. Detaching on-device makes the result survive the transport.

---

## 5. Concurrency and flaky infrastructure

**L21 — Prove flakiness; never assume it.**
Attributing a failure to "contention", "flakiness" or "environment" without evidence is the
single most common failure mode here. Re-run it and read the actual error. One RED blamed on
contention was a real failure: a lane had committed a hardcoded lab IP.

**L22 — Known race: `test_main_guard`.**
`tests/unit/test_main_guard.cpp:64-71` and `:103-104` give a bounded 40 × 50 ms = 2.0 s window
for a post-`SIGSTOP` scheduler transition, which can produce a spurious
"fake MiSTer did not reach state T" under heavy parallel load. It is **deliberately not
fixed** — widening the bound to silence it is gate self-weakening. Re-run, report both
results, and label it explicitly. Never apply this label to a different error.

**L23 — Build unconditional restore into any script that stops the daemon.**
Device connectivity drops intermittently; a half-finished experiment must not leave the device
without its supervisor.

---

## 6. Storage and provenance

**L24 — `/tmp` is tmpfs and is erased on reboot.**
It has already destroyed session history once. Nothing of value lives there: neither evidence
nor git worktrees. Permanent store is `Memory/` (see `AGENTS.md`).

**L25 — Never record a Plex token.**
A live `X-Plex-Token` is visible in ffmpeg's argv on device, so any local process can read
`/proc/<pid>/cmdline`. Tokens are never copied into the store and are redacted from anything
that is.

---

**L28 — The deployed bitstream is NOT your source tree. Verify provenance before inferring
anything from the device.**
`Plex.rbf` md5 `dfebf2bf` was assumed to match current RTL. It is the **G-VID1** build from
FPGA commit `0139f2c5`, where `ddr_frame_store.sv` **does not exist** — that file was added
later in `d0ea6dac` (`git merge-base --is-ancestor 0139f2c5 d0ea6dac` → rc=0). Mailbox
probes against that core returned zeros, and the zeros were read as "the core fails to
publish PLXD". The real reason is that the running core has **no PLXD writer at all**.
Before drawing any conclusion from a device probe, answer: *which commit built the
bitstream I am probing?* If that cannot be answered in one command, the tooling is the bug.

**L29 — `git worktree move` cannot relocate a worktree off `/tmp`.**
It uses `rename(2)`, which fails across filesystems with `Invalid cross-device link`
(tmpfs → btrfs). Use `cp -a <src> <dest>` then `git worktree repair <dest>`, then remove
the original. Commits in a *branch-named* worktree are safe in the shared object DB, but a
**detached HEAD** worktree's commits are GC-reachable only while registered — tag them
before pruning.

---

## Incident index

| # | Wrong conclusion | Reality |
|---|---|---|
| 7 | Symbol unconfirmed after one grep | Wrong file; it existed elsewhere |
| 8 | SD playback would fail (pre-registered) | Played fine; recorded failure was transient |
| 14 | PMS rewrites the source profile | PMS **preserves** it through transcode |
| 17 | Deleting CABAC recovers area | Worth **zero** — ALM 0, M10K 0 |
| 18 | Route A killed by Fmax | Critical path ran through a stub slated for deletion |
| 19 | Five 720p modules landed on main | Measured the wrong tree; broadcast to 9 agents |
| 20 | `make unit` rc=0 means PASS | Run contained SKIP-NOT-PASS markers |
| 21 | Black captures ⇒ dead RBFs | `load_core` thrash invalidated daemon FPGA handles |
| 22 | Release core was broken | Had been paired with a mismatched dev daemon |
| — | ARM saturated at idle | First sample contained a live transcode; retracted, then re-established |
| — | Two PLXG constants conflicted | `0x300FF000 + 0x800 == 0x300FF800` — identical; a pure duplicate |
| — | PLXD alive at the doorbell-relative address | Zero at **every** candidate; only the host-written doorbell was live |
| — | Those PLXD zeros indicted the RTL | The deployed RBF predates `ddr_frame_store.sv` entirely — it has **no PLXD writer**. Probe was invalid; conclusion withdrawn |
| — | `misterplexd` ~136% + `MiSTer` ~131% at idle | Arithmetically impossible: 16.02 CPU-s claimed inside a 12 CPU-s dual-core window. Split withdrawn |
| — | Native 720p24 is arithmetically dead at 0.939× | **1.31× (32 fps)** with the daemon stopped. The wall was a daemon busy-loop, not physics |

Full narrative for each: `Memory/lab/parent/misterplex-parent-720p-decode-verdict.txt`.
