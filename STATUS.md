# MiSTerPlex — Live Status

Auto-published by the parent orchestrator every ~30 minutes.
Newest update at the top. Read this file on your phone at:
`https://github.com/flynnsbit/MisterPlex/blob/status/STATUS.md`

**Goal:** move H.264 decode off the ARM and into FPGA fabric, so the DE10-Nano
plays Plex content natively.

---

## Update #1 — 2026-07-28 11:12 CDT (Hour 28)

### Headline

**The first timing-clean RBF has been authorized for deploy. It is not on the
device yet.** I verified this directly rather than trusting the worker report:

```
device /media/fat/_Utility/Plex.rbf  md5 = 00eebd5e   <- OLD build, still resident
authorized build                     md5 = fb4bad84   <- built, held, deploying
```

So: **do not expect the MiSTer to behave differently yet.** When update #2 says
the device md5 reads `fb4bad84`, that is when it is worth looking at the screen.

### Progress toward full FPGA PlexCast

```
ARM / Plex client        ████████████████░░░░  85%   cast + timeline verified on device
Integrity / release      ██████████████░░░░░░  70%
Display path (frame st.) ██████████░░░░░░░░░░  50%   fix proven in sim, NOT yet on hardware
Shippable builds         ██████████░░░░░░░░░░  50%   ARM shipped; RBF deploying now
Picture: intra (stills)  █████████░░░░░░░░░░░  45%   reaches pixels, only 4/256 exact
Bitstream parse / CAVLC  ████████░░░░░░░░░░░░  40%
Deblocking filter        ██████░░░░░░░░░░░░░░  30%   seam-order errors currently RED
Picture: inter / motion  ██░░░░░░░░░░░░░░░░░░  10%   not implemented, not measured
                                              ─────
OVERALL                  ███████░░░░░░░░░░░░░  35%
```

**The number that matters: zero frames have ever been decoded and displayed by
the FPGA.** Everything above is scaffolding until that changes.

### What actually moved this hour

**1. The deploy blocker was cleared — and my own theory was wrong.**
I had suspected three `set_false_path` timing exclusions were hiding the known
`-2.137 ns` violation on exactly the modules the build was meant to fix. They
were converted to bounded `set_max_delay 50.0` and re-run both ways:

```
WITH old exclusions:     setup +0.185 ns   hold +0.248 ns   negative rows 0
WITHOUT old exclusions:  setup +0.185 ns   hold +0.248 ns   negative rows 0
```

Identical. **The exclusions were not hiding anything.** Timing is genuinely
closed, and the RTL invariant now *rejects* such cuts outright rather than
allowing reviewed exceptions.

**2. An adversarial auditor (on a different model) found six real defects in our
own test gates.** This was the highest-value thing to happen today. The worst:

- The reachability checker — the tool every architectural conclusion rests on —
  has **both false-positive and false-negative blind spots**. It reads source
  text, it does not elaborate the design.
- **24 test paths can exit `0` (pass) where they should exit `77` (skip).**
- **The timing-exclusion gate can pass without an STA report present at all.**

It could *not* break the three most load-bearing claims: the frame-store
livelock fix, the deblock seam ordering, or the chroma-QP trap. The livelock fix
is the entire content of the build now deploying.

**3. A worker corrected itself on a claim I had already accepted.** This is the
one I want on the record. `w-decode` reported the decoder rewire complete with
`reachable = 50`. It then re-measured and withdrew it:

```
present under the real core:      8 modules
NOT present under the real core:  8 modules
   incl. h264_inter_mc_16x16, h264_dpb_one_ref, h264_deblock_writeback_ctrl
```

The `50` was inflated because a retired diagnostic module (`decode_stub`) is
still instantiated, and the counter reached motion-compensation hardware
*through the stub* rather than through the product decoder. **The rewire is
about half done, not done.**

### The pattern I am now watching for

Three times this project has shipped a "working" subsystem that **was not
connected to the product at all** — the intra predictor, the CAVLC residual
decoder, and now motion compensation. Every unit test passed in all three cases,
because the tests instantiated the modules directly.

Standing rule for the fleet: *prove a module is reachable from the product root,
not that its testbench passes.* The auditor's finding that this very checker is
unreliable is therefore serious, and fixing it is now ahead of feature work.

### Your two open hardware defects

| Defect | Status |
|---|---|
| Cast shows available, play never starts, web player stuck at 0:00 | `w-cast` — found 2 real product bugs, parser now covers 1170/1170 macroblocks of a real P-frame |
| Screensaver / Plex logo black, menu reachable | `w-osd` — active |
| Left-edge jagged black lines, moving | `w-arm` — RCA below |

On the left-edge artifact, the measured mechanism beats the theory I had.
Telemetry shows the present path wedged at `free=0 disp=1 swap=1` while frames
keep advancing — so the ARM fallback **writes into the buffer currently being
scanned out**, every other frame. That explains *moving* corruption; my stride
theory would only produce static skew. This fix will be deployed **separately**
from the RBF, so that whichever one fixes it is attributable.

### Note on which RBF you are running

There were two, and one was a trap:

```
/media/fat/Plex_20260727.rbf   9f364cb1   STALE + banned  -> renamed to .stale-9f364cb1
/media/fat/_Utility/Plex.rbf   00eebd5e   the only deploy target
```

The stale root copy is now renamed (not deleted, so it is reversible) and can no
longer be launched by accident. **Always launch from `_Utility`.** A build ID in
the OSD is being added so this is self-evident from the screen — derived from
the bitstream itself, not a hand-edited constant that can lie.

### Fleet

13 workers. Migration to `claude-opus-5` in progress with written handoffs
(measured-vs-assumed, what did *not* work, and peer-negotiated interface
contracts). One auditor stays on `gpt-5.5` deliberately — a same-model reviewer
tends to share the original's blind spots.

```
live on opus-5    w-arm-o5   w-gate-o5   w-fit-o5
auditor (gpt-5.5) w-audit
awaiting handoff  w-swap  w-decode  w-cast  w-osd  w-deblock  w-e2e
stood down        w-arm   w-gate   w-fit
```

Testing is now fully automated end to end — HDMI capture off the real MiSTer on
`/dev/video0`, and Playwright against the Plex web player. No human in the loop.

### Next update

~30 minutes. It will lead with whether the device md5 changed to `fb4bad84` and,
if so, whether `disp_bank` toggles repeatedly with `swap_pending` returning to
zero. **Build-OK and deploy-OK are not success. A moving picture is success.**
