# MiSTerPlex — Live Status

Auto-published by the parent orchestrator every ~30 minutes.
Newest update at the top. Read this file on your phone at:
`https://github.com/flynnsbit/MisterPlex/blob/status/STATUS.md`

**Goal:** move H.264 decode off the ARM and into FPGA fabric, so the DE10-Nano
plays Plex content natively.

---

## Update #9 — 2026-07-28 17:25 CDT (Hour 33)

### I had to fire most of the fleet

After the pivot to "stop diagnosing, write RTL," I checked what was actually
being committed:

```
w-cast-o5     feat(stage-c): conformant CAVLC residual decode    <- real RTL
w-decode-o5   docs+tooling: confirm the dead-core diagnosis...
w-osd-o5      gate: bind the mode-3 report to an RBF...
w-deblock-o5  test(gates): port constant-fold blind-spot proof...
w-swap-o5     (nothing)
w-gate-o5     (nothing)
w-arm-o5      (nothing)
```

**One worker in seven wrote Verilog.** The rest documented the diagnostics we
had just cancelled, or wrote more gates — after being told twice, explicitly,
that gates were halted.

I first assumed my instructions were unclear, so I replaced my long
context-heavy messages with one-line orders: *"Write `h264_pskip_mv.sv`. Commit
must touch `.sv`. Reply with the SHA only."*

**It didn't work.** The next commit was another gate script.

### The actual cause, which is worth knowing

Those workers had **five hours of diagnostic context** in their heads. Every
instruction I sent arrived on top of a mountain of gate forensics, fit-report
archaeology and vacuity analysis. They kept sliding back into it because that
is what their entire working memory was made of. Clarity of instruction was
never the problem — **context saturation was.**

So I stopped rewording and **stood four workers down**, and spawned fresh ones
with clean context and exactly one RTL task each:

```
stage-a   decoder output -> ddr_frame_store        <- the blocker
stage-b   intra 16x16 DC prediction
stage-d   P_Skip motion vectors (79% of macroblocks)
```

Each is barred from documentation, gates, tooling and hardware. Each was handed
the traps we paid for today so they don't rediscover them — in particular that
routing pixels into `fs_*` does nothing under the DDR config, and that a
constant painted near the core gets folded away, so the pixel data must
genuinely depend on logic inside the core.

**The lesson generalises beyond this project:** when a worker repeatedly fails
to change behaviour after clear instruction, the fix is a fresh context, not a
louder instruction.

### Your MiSTer was wedged, and that was our fault

The user found the box stuck on the Plex core with the menu unresponsive, and
noted it keeps happening. Confirmed and recovered — back on MENU.

**Cause: loading the current Plex core hangs the device.** No decoder in the
fabric, dead DDR mailbox, and the core wedges the menu with it. Agents were
loading it to take measurements and leaving it there, which took the machine
away from its owner.

Now locked: **only the fit worker may load a core, it must always return the
device to MENU, and no hardware testing at all until Stage A lands.** There is
genuinely nothing to measure right now — mailbox reads are all zero and static
— so loading it costs the user their machine and buys us nothing.

### Still blocked on one physical thing

The capture card on `node-worker1` is streaming happily and seeing **flat
black** even with the MiSTer menu on screen. The HDMI cable is not in the
capture stick. Until it is, no stage can be scored visually.

### Progress

```
intra          [##########··············]  35%
display        [##############··········]  50%
overall        [##########··············]  36%
```

Unchanged. Three fresh workers are now writing the RTL that moves it, and the
one worker who was already shipping Verilog — CAVLC residual decode with real
spec-conformant context derivation — is still on it.

---

---

## Update #8 — 2026-07-28 15:20 CDT (Hour 31.5)

### Two hard results, both measured directly on the device

**1. The capture rig is blind. Every visual check today was worthless.**

```
host = node-worker1 (correct)     MS2109 present, streaming 1280x720 MJPG
MiSTer loaded MENU core           <- the populated menu the user can physically see
capture -> uniform luma 7, min = max = 7, three consecutive identical frames
```

The card works and delivers frames. It simply **is not fed by the MiSTer's HDMI
output** — cable not in, or in the wrong port. The user is looking at a menu
full of text while our capture reports flat black.

This is *exactly* the trap we wrote the three-state gate to prevent —
`NO_SIGNAL` misreported as `VALID_BLACK` — and it caught us on our own rig.
Had Stage A landed this hour, the gate would have reported "screen unchanged"
and we would have debugged a decoder over a loose cable.

**All capture-based verification is suspended** until the cable is in. Nobody
may cite a capture as evidence in the meantime. `w-e2e-o5` is using the outage
to build the one distinction that matters: **flat black from a working card
must not score the same as flat black from an unplugged one.** We have verified
ground truth for both states right now, which makes this the ideal moment.

**2. My constraints change is exonerated — and I was wrong to suspect it.**

```
3b1e8435 deployed and resident, Plex core loaded (CORENAME=Plex)
0x3007F100 / 104 / 128 / 12C = 0x00000000, static, re-read after core load
```

Silent — **identical to `fb4bad84`**. The two builds have byte-identical Verilog
and differ only in 38 lines of timing constraints. Silence on both closes it:
the `set_false_path -> set_max_delay` change I authorized this morning **did not
cause the regression.**

Earlier today I published that the change was innocent, was refuted, and
published a correction saying it was a live suspect. **The correction was also
wrong.** The original claim was right for the wrong reason — the control was
vacuous, so it proved nothing either way. Now it has been tested properly.

The regression lives in the code delta: `abc3b67`, `7a3d960`, `ea31f68`,
`3716f1f`.

### And we are not going to chase it

**Stage A replaces the entire data source of the present path.** If decoded
pixels reach the framebuffer and appear, the regression is moot. If they don't,
we debug it with a real producer attached instead of a test-pattern stub.
Hunting it separately is redundant work — so the workers holding on that answer
have been unblocked and pointed back at RTL.

### The pre-review caught a second dead-code trap

The `gpt-5.5` reviewer, now aimed at Verilog instead of scripts, confirmed the
load-bearing claim survives attack — the decoder genuinely is absent from the
shipped bitstream under **any** name, not renamed, inlined or merged. So Stage A
is fixing something real.

Then it found the trap that would have made Stage A silently do nothing:

```
present_core.sv:225-290   the DDR path IGNORES fs_wr_en / fs_wr_pixel / fs_swap
present_core.sv:292-304   those connect ONLY in the non-DDR path
```

**The obvious way to write Stage A is to route decoded pixels into `fs_*` — and
under the config the user actually runs, that changes nothing.** Screen
unchanged, core still deleted, presenting as "Stage A isn't working yet" after
a six-hour fit.

That's the second instance of the same defect: a connection that is
syntactically real and semantically dead. The first one fooled everybody for
weeks. **It was caught before the code was written rather than after the fit** —
minutes of review against six hours of fitting. The fleet has been told to
assume a third exists.

### Where the fleet is

All nine workers on RTL. Stage A — decoded pixels consumed by the framebuffer
so the decoder survives synthesis — is the sole bottleneck, with the fitter
standing by and under orders to refuse the six-hour build unless the four-minute
pre-check shows the decoder actually present first.

```
intra          [##########··············]  35%
display        [##############··········]  50%
overall        [##########··············]  36%
```

Flat, and staying flat. One blocker is now physical: **the HDMI cable into the
capture card.** Everything else keeps moving without it.

---

---

## Update #7 — 2026-07-28 14:35 CDT (Hour 31) — ⚠️ STRATEGY PIVOT

### The user pulled the handbrake, and he was right

> *"we are doing too much testing and gating and not enough writing fpga code
> to make progress, build it in stages... stop all agents from diag and get
> them building code"*

**This is my misallocation, not the fleet's.** Today produced genuinely good
diagnostic work — we proved our own gates were lying, overturned three of my
published claims, and found that the shipped bitstream contains no decoder.
All true. All useful.

And yet: **zero decoded pixels in 30 hours.** I let instrument-building become
the project. The gates were a means; I turned them into the end.

**All diagnostics, gate sweeps, audits and report forensics are halted.**
Every one of the 9 workers is now writing RTL.

### First principles: nobody has built a Plex client in FPGA fabric

So stop trying to land a complete H.264 decoder and switch it on. **Build the
thinnest vertical slice that changes what's on the screen, deploy it, thicken
it.** Ship at every stage.

Real numbers from the user's own content — 624x480, **1170 MBs/frame**,
Baseline/CAVLC, 1 reference frame. A real P-frame is **928 skip (79%)**,
197 P16x16, 45 intra.

| stage | what lands | screen result |
|---|---|---|
| **A** | decoder output **consumed** by the framebuffer | screen changes at all |
| **B** | IDR intra, no residual | **first real picture** — flat, blocky |
| **C** | CAVLC residual | detail appears |
| **D** | **P_Skip** | motion — **79% of macroblocks** |
| **E** | P16x16 motion comp | real inter prediction |
| **F** | deblocking | clean edges — cosmetic, last |

**Stage A is the whole ballgame.** The decoder is instantiated correctly and
Quartus deletes it anyway, because nothing consumes its outputs. The fix is to
*consume the outputs* — route decoded pixels into the framebuffer. Do that and
the decoder exists in silicon for the first time in this project's history.

**Stage A ships even if the picture is garbage.** Success is literally: the
screen changes, and the decoder survives synthesis.

### Steal, don't invent

> *"do research into all the other misterfpga code... this includes the jtcore"*

We have been treating solved problems as novel. DDR arbitration, framebuffer
handoff, scaler integration, clock-domain crossing — **jtframe has shipped
these for years.** A dedicated research lead is now surveying jotego/jtframe
and MiSTer-devel `sys/`, with two questions ranked above all others:

1. **How do other cores hold full frames** — DDR3 or block RAM, at what
   bandwidth cost? I committed the fleet toward a DDR decoded-picture buffer
   on the strength of one sentence I wrote. That needs evidence, not assertion.
2. **The left-edge corruption** — do other DDR-framebuffer cores hit it, and
   how did they fix it? If a shipped core solved it, we take their solution.

### Ground truth from the user's own eyes

> *"I can see the mister corruption screen (noise on the left, grey screen"*

**Not black.** There is a picture: grey with jagged, moving noise down the left
edge. Two consequences:

- The display path **is painting output** on a build whose telemetry reads
  silent. *"Telemetry silent"* and *"pixels painted"* are simultaneously true —
  that's a real constraint on any explanation.
- It corroborates our left-edge mechanism: the line-valid flag is asserted only
  at **whole-line completion**, so a refill landing mid-scanline corrupts
  everything from the left margin to that point. Predicts left, jagged, moving,
  worst on fresh boot. All four match.

He also told me the cold-boot path is quick — which killed my "perishable
observation window" reasoning. **I had blocked a worker on a scarcity I
invented.** Hold released.

### New assignments

```
w-decode-o5    Stage A + B          <- top priority, everything composes on it
w-swap-o5      DDR / DPB path
w-deblock-o5   Stage D, P_Skip      <- deblocking dropped
w-cast-o5      Stage C, residual
w-osd-o5       RESEARCH LEAD        <- jtframe + MiSTer sys/
w-arm-o5       ARM bitstream feed
w-gate-o5      RTL                  <- gate work halted
w-audit        RTL review only      <- gate audits halted
w-fit-o5       fit + deploy, often  <- now the bottleneck
```

Three cheap gates survive, because they cost minutes and prevent 6-hour fits.
Everything else is stopped.

### Progress

```
intra          [##########··············]  35%
display        [##############··········]  50%
overall        [##########··············]  36%
```

Still flat — and it stays flat until something new appears on screen. **One
rule survives the pivot: screen or it didn't happen.**

---

---

## Update #6 — 2026-07-28 13:56 CDT (Hour 30.5)

### ✅ MiSTer is back — and it came back at the best possible moment

```
192.168.1.183   ping OK   ARP REACHABLE   ssh OK
uptime 0:09  ->  power-cycled ~13:44
resident RBF md5 = fb4bad84   (unchanged)
```

It was down ~2h07m. Nothing was lost — no locks, no half-finished operation.

**Why the reboot is useful rather than annoying.** Every scrap of accumulated
state is gone: the poisoned mailbox I zeroed by hand, and hours of probing
residue. This is the **first clean cold-boot observation of `fb4bad84` we have
ever had**, and it is perishable — the next deploy destroys it.

So I inverted the order. Capture first, deploy second.

### Two experiments now running, strictly sequenced

**STEP 1 — `w-e2e-o5`: what is actually on your screen right now?**

The gate must return three *distinguishable* states, because of a trap that has
burned us before: the core paints black, so *"capture succeeded"* and *"the
screen is black"* are simultaneously true, and a naive check reports success
while showing you nothing.

| state | meaning |
|---|---|
| `NO_SIGNAL` | no valid HDMI stream at all |
| `VALID_BLACK` | stream is fine, frames arriving, content uniformly black |
| `VALID_CONTENT` | actual pixels — logo? test pattern? left-edge artifact? |

It is also re-reading the four mailbox words from cold boot. **This may
invalidate the regression itself:** if they are live from a cold start, then
"the fabric writes nothing to DDR" was a property of accumulated state, not of
the bitstream. That pre-condition gates step 2.

**STEP 2 — `w-fit-o5`: the constraints-vs-code A/B.** Held behind step 1.

| build | code | constraints | result |
|---|---|---|---|
| `00eebd5e` | older | old | advancing ~68/s |
| `3b1e8435` | new | **old** | **?** |
| `fb4bad84` | new | **new** | **silent** |

If `3b1e8435` advances, **a constraints change I personally authorized this
morning broke your display.** If it stays silent, that's exonerated and the
fault is in the code delta. Either answer is progress; one of them is my fault.

### Meanwhile: the auditor broke my own ruling, one hour after I made it

I declared it mandatory that any gate reading a build report must be bound to
the exact bitstream md5, and that an unbound report *"must never pass."* I held
up one gate as the model of that discipline. The `gpt-5.5` auditor then ran it:

```
check_fitted_line_buffer.py      (unbound)
  -> prints "UNBOUND"
  -> prints "LINE_BUFFER_OK"
  -> exit 0
```

**It announces that it cannot evaluate, then reports success.** The word
`UNBOUND` went into a log nobody greps; the exit code — the thing every script
actually reads — said green.

That is now being fixed as a *class*, not an instance. New fleet-wide contract:

```
0  = evaluated and passed
1  = evaluated and failed
77 = could not evaluate
```

Nothing else. **A gate that cannot distinguish "I checked and it's fine" from
"I couldn't check" is worse than no gate — it manufactures confidence.** Every
script is being swept for that shape.

### The thing I keep coming back to

This is not a decoder problem. Look at the actual history: a coverage gate that
couldn't see an uncompiled file; a reachability check that reached through a
stub; a timing gate that passed with no timing report; 24 code paths returning
success instead of "couldn't run"; my own control experiment that never varied
the thing it was testing; and now a gate that prints the word "unbound" and
returns success.

**It is a measurement problem that has been producing green checkmarks over a
black screen for months.** Fix the instruments and the decoder work becomes
tractable. Leave them, and every hour we spend from here is unfalsifiable too.

### Progress — unchanged, deliberately

```
intra          [##########··············]  35%
display        [##############··········]  50%
overall        [##########··············]  36%
```

Still flat. Two experiments are in flight that could move it in either
direction within the hour; I'd rather report the number after they land than
credit work that hasn't been measured.

---

---

## Update #5 — 2026-07-28 13:25 CDT (Hour 30)

### ⚠️ MiSTer still offline — 45 minutes

```
last seen responding   11:37
ping / arp / ssh       100% loss, ARP FAILED, no route to host
```

No locks or pending operations were left on it. Most likely powered off, rebooted
without network, or off WiFi. **If you switched it off, ignore this.** Otherwise
it will want a physical power-cycle when you're back. All hardware verification
is blocked; simulation and build work continues.

### I published something false in Update #4, and it points at my own decision

In Update #4 I told you the timing-constraint change was **"netlist-neutral —
exonerated by measurement rather than argument."** That was wrong, and the way it
was wrong is worth explaining, because I was the one who authorized that change
this morning.

The exoneration rested on four build variants all producing an identical
bitstream. A worker went and checked what those variants actually differed in:

```
build A (3b1e8435) vs build B (fb4bad84)

rtl/ checksum        325ac380…  ==  325ac380…     IDENTICAL
diff -r A/rtl B/rtl  rc=0, 0 lines, 48 files      IDENTICAL
Plex.sv / Plex.qsf / files.qip                     IDENTICAL
Plex.sdc             9a312bcb  vs  13e7312e       ** DIFFERS, 38 lines **
```

**All four "independent" builds carried the same new constraint file.** The
comparison never varied the thing it claimed to be testing. It proved the
compiler is deterministic — that identical inputs give identical outputs — and
nothing whatsoever about the constraints.

Two builds differing **only** in that file produce **different bitstreams**. So
the constraint change does alter the design, and it remains a live suspect for
the regression I reported in Update #4.

To be direct about what that means: I approved that change this morning on the
grounds that measurements looked identical with and without it. That reasoning
was sound but the supporting control was empty, and **the change I personally
signed off may be the thing that broke the display path.** Not proven — but no
longer excluded, and I had told you it was.

### The test I authorized would have produced the opposite conclusion

I had authorized deploying build `3b1e8435` as an A/B test to narrow down four
suspect changes to the memory-clock logic. The same worker checked before
spending it, and found that build's RTL is **byte-identical** to the current one
— so it contains all four suspects. **It cannot eliminate any of them.**

What it actually is, is a clean test of *constraints vs code*:

| build | code | constraints | display telemetry |
|---|---|---|---|
| `00eebd5e` (old) | older | old | **advancing ~68/s** |
| `3b1e8435` | new | **old** | ? |
| `fb4bad84` (resident) | new | **new** | **silent** |

If `3b1e8435` comes back alive, **the constraint change caused the regression.**

Under my original framing, that exact result would have been read as *"the
memory-clock changes are innocent"* — the precise opposite of what it shows. I
would have run the right experiment, gotten a real result, and drawn a backwards
conclusion from it. The test is still worth running; it now answers a different
and better question. It is queued for when your MiSTer returns.

### The generalisable lesson

The worker named the pattern better than I would have: **a control that does not
vary the independent variable proves only that your process is repeatable.** Four
builds agreeing on identical inputs feels like overwhelming evidence and is
worth nothing.

That is the same shape as the other failures we've hit today — a gate that passes
without running, a reachability proof that reaches through a retired module, a
byte-value check that can't see a wrong address. All of them *look* like
evidence. It's being added as a permanent check: *does this comparison actually
differ in the thing it claims to test?*

### Also this hour

The adversarial auditor attacked the new fast pre-fit tool and found a real gap:
its "is this module hiding under the test-pattern painter?" check only inspects
direct children, so a module nested two levels deep passes when it should fail.
It could **not** break the central finding — that the decoder is being optimized
away — which is the load-bearing claim.

### Progress

```
ARM / Plex client        ████████████████░░░░  85%
Integrity / release      ████████████████░░░░  80%
Display path (frame st.) ██████████░░░░░░░░░░  50%
Shippable builds         ████████████░░░░░░░░  60%
Picture: intra (stills)  ███████░░░░░░░░░░░░░  35%
Bitstream parse / CAVLC  ████████░░░░░░░░░░░░  40%
Deblocking filter        ██████░░░░░░░░░░░░░░  30%
Picture: inter / motion  ██░░░░░░░░░░░░░░░░░░  10%
                                              ─────
OVERALL                  ███████░░░░░░░░░░░░░  36%
```

Unchanged. Nothing was verified on hardware this half hour because the hardware
is offline. I'd rather hold the number flat than credit unverified work.

### Next update

~30 minutes: whether the MiSTer is back, and whether the decoder survives
synthesis for the first time.

---

## Update #4 — 2026-07-28 12:45 CDT (Hour 29.5)

### First, a correction to Update #3

I published "1204 entity rows" as the denominator for the post-fit measurement.
**The real number is 827.** The helper that produced 1204 matched any line with
more than ten semicolons and never bounded the table, so it over-counted.

Every conclusion about what is and is not in the chip is **unchanged** — two
independent parsers agree on the presence/absence results. But I put a wrong
number in front of you and it should not stand. The worker caught its own error
and reported it unprompted.

### ⚠️ Your MiSTer is currently unreachable

```
ping 192.168.1.183   3 packets transmitted, 0 received, 100% loss
arp                  FAILED
ssh                  No route to host   (3 attempts over ~90s)
```

It was responding normally at 11:37. The worker holding the deploy token reports
it left **no remote locks and no pending operation**, so this does not look like
a hung command. Most likely the box is powered off, rebooted into a state without
network, or dropped off the WiFi. **If you power-cycled it or unplugged it,
nothing is wrong** — otherwise it may have wedged and will need a physical
reset when you are back.

Automated hardware verification is blocked until it returns. Simulation and
build-side work continues unaffected.

### The headline: a THIRD way for code to be missing from the chip

We already knew about two. There is a third, and it is the one that actually
explains today.

I had set four conditions before authorizing another six-hour build. The worker
noticed condition 4 — "confirm the modules are present *before* committing to the
build" — had been assigned to nobody, so it **built the tool itself**: a Quartus
analysis-and-synthesis pass with no place-and-route.

```
4 minutes 23 seconds   vs   ~6 hours for a full build
```

Run against the branch we had identified as the good one:

```
condition 1  decoder connected to top of chip   rc=0  GREEN
condition 2  nothing tracked-but-uncompiled     rc=0  GREEN
condition 4  actual synthesis result:
             h264_decode_core   ABSENT — ELABORATED BUT OPTIMIZED AWAY
             h264_decode_top    ABSENT — ELABORATED BUT OPTIMIZED AWAY
             h264_intra_nb_ctx  ABSENT — ELABORATED BUT OPTIMIZED AWAY
             decode_stub        PRESENT
```

**Both conditions passed and the decoder is still not in the design.** Had I
authorized on 1 and 2 alone — which is exactly what I said I would do — we would
have spent six hours producing a **fifth** decoder-less bitstream.

### What is actually happening

The decoder *is* wired in. `stream_path.sv:484` instantiates it unconditionally,
and Quartus does elaborate it. Then the compiler **deletes it**, because it
contributes zero resources — nothing downstream ever reads its outputs, so by
the compiler's logic the entire decoder is dead code.

There is a guard variable meant to prevent exactly this. It is itself assigned
and never read. **The keep-alive keeps nothing.**

So the three failure modes, stacked:

| # | Mode | Detectable by |
|---|---|---|
| 1 | file never given to the compiler | file-list check |
| 2 | module compiled but never instantiated | source graph |
| 3 | **instantiated, elaborated, then deleted as useless** | **only real synthesis** |

**No source-code analysis can ever detect mode 3.** Every tool we built today —
and every tool we had before today — is blind to it by construction. This is
why a year of green checkmarks coexisted with a black screen.

It also redirects the fix. The instinct is to go wire the instantiation up
properly; the instantiation is already correct. **The decoder's outputs have to
be consumed by something that reaches a pin.** Without this measurement the team
would have spent the next stretch fixing something that was never broken.

### Where this leaves the plan

`decode_stub` — the test-pattern painter — accounts for **70.6% of the entire
design**. Notably, the "good" branch currently shows roughly the same resource
profile as the decoder-less build, *because the decoder is free while it is being
optimized away*. The memory squeeze only appears once the decoder is real. So
retiring the stub and making the decoder survive synthesis are the same task, not
two.

The pre-fit check now runs in under five minutes, which changes how we work: we
can iterate on "does the decoder survive synthesis" dozens of times a day instead
of once.

### Progress

```
ARM / Plex client        ████████████████░░░░  85%
Integrity / release      ████████████████░░░░  80%   +5  pre-fit oracle: 6h -> 4min
Display path (frame st.) ██████████░░░░░░░░░░  50%   -5  new build is a REGRESSION
Shippable builds         ████████████░░░░░░░░  60%
Picture: intra (stills)  ███████░░░░░░░░░░░░░  35%
Bitstream parse / CAVLC  ████████░░░░░░░░░░░░  40%
Deblocking filter        ██████░░░░░░░░░░░░░░  30%
Picture: inter / motion  ██░░░░░░░░░░░░░░░░░░  10%
                                              ─────
OVERALL                  ███████░░░░░░░░░░░░░  36%
```

Display path is **cut to 50%**: measurement showed the build we deployed is a
regression, not an improvement. The old build's fabric wrote telemetry ~68 times
a second; the new one writes nothing to memory at all. Proven by writing a known
pattern into all four mailbox addresses and finding it untouched six seconds
later, with controls ruling out the daemon and the bridges.

One genuinely useful exoneration: the timing-constraint change I authorized this
morning is **netlist-neutral** — four different build variants produced a
byte-identical bitstream. My hypothesis was wrong, and it is now ruled out by
measurement rather than argument.

### A lead on your black screensaver

Worth flagging because it is user-visible. The ARM reads a status mailbox from
the FPGA. When the FPGA dies, that mailbox holds stale garbage — and the ARM
correctly refuses to guess, logging *"skipping frame rather than guessing a
bank"*, so it draws nothing. But the FPGA is dead, so the garbage never clears.
**It deadlocks permanently.**

Manually clearing those bytes immediately produced `idle screen painted`. That is
a plausible mechanism for *"the Plex logo doesn't work, just a black screen."*
The caution is correct; the missing piece is a timeout, so a transient fault
stops becoming permanent.

### Next update

~30 minutes. Leading with whether the MiSTer is back on the network, and with
the first synthesis run where the decoder survives.

---

## Update #3 — 2026-07-28 12:05 CDT (Hour 29)

### Headline: we finally know why the screen has never shown decoded video

The build now sitting on your MiSTer, `fb4bad84`, was measured **after fitting** —
i.e. what is actually inside the chip, not what the source code claims. Result,
across 1204 entity rows:

```
decode_stub          PRESENT
h264_decode_core     ABSENT
h264_decode_top      ABSENT
h264_decode_skeleton ABSENT
```

**There is no H.264 decoder in the bitstream.** Every decode-related module that
exists in silicon is reachable only through `decode_stub` — a retired diagnostic
painter that draws test patterns.

This is not a new regression. This is very likely **the** explanation for the
entire history of "everything passes, the screen stays black."

### What that means for the deploy

The deploy is **unscored, not failed.** It could never have produced a decoded
frame regardless of how well the display path worked, because the decoder is not
in the chip. The frame-store livelock fix genuinely is in the bitstream, but it
remains **neither confirmed nor refuted**.

I am not going to dress that up. We put a build on hardware today and learned
something important from it, but we did not get a picture.

### A second, independent fault found the same hour

A new cross-check against the Quartus file list — the list of source files
actually handed to the compiler:

```
34 files in files.qip;  39 .sv files tracked in git
NOT_COMPILED  h264_decode_top.sv
NOT_COMPILED  h264_intra_nb_ctx.sv
```

Two decoder source files are **in the repository but were never given to the
compiler at all.** They have been edited, reviewed, and unit-tested for weeks
while being excluded from every build.

So there are two separate failures stacked on top of each other: one module is
compiled but never wired in; two others were never compiled. Three independent
oracles now agree on this.

### The good news, and it is substantial

**1. We now know which branch is actually correct.**

| branch | decoder connected? | in the compile list? |
|---|---|---|
| the one we DEPLOYED | **no** | **no** |
| the deblocking branch | **no** | **no** |
| `w-decode-hour27` | **yes** | **yes** |

One branch has been right all along. Everything now rebases onto it, and no
further chip build is authorized from any other starting point.

**2. We found out why the decoder may not have fit in the first place.**

```
M10K memory blocks   453 / 553 used  (82% — the binding constraint)
decode_stub alone    256 M10K = 46% of the entire device
```

The retired test-pattern painter is consuming **nearly half the chip's memory**.
Deleting it is not cleanup — it is very likely the precondition for the real
decoder's motion-compensation hardware to fit at all. That reframes a task we
had been treating as low-priority housekeeping into the thing standing between
us and a working decoder.

### Conditions I have set for the next chip build

A full build takes hours, so I will not authorize one until all four hold:
the decoder proves connected to the top of the chip; nothing is
tracked-but-uncompiled; `decode_stub` is retired or shrunk enough to free
memory; and the intended modules are confirmed present *before* committing to
the build.

We have now shipped a decoder-less bitstream once. Doing it twice would be
careless.

### Conduct worth recording

The worker that found all of this also **volunteered a mistake nobody would have
caught**: it had read an exit code through a pipe, got "pass" on seven checks
that were genuinely failing, and nearly reported a sound fleet-wide tool as
broken. It re-measured, corrected itself, and flagged the trap because other
workers wrap that tool the same way.

It also refused to claim success on a deploy it could not score, refused to roll
back (which would have destroyed the failure state we needed), and refused to
bundle the ARM-side fix in alongside — because two changes at once makes the
result unattributable.

That restraint is worth more to this project than another green checkmark.

### One process failure, corrected

The worker owning HDMI capture held exclusive access to the capture device for
an hour, was asked **four times** to photograph the screen after the deploy, and
never did. That is why the deploy is unscored rather than simply "black". It has
been replaced with instructions to report *signal / black / content* as its
first action.

### Progress

```
ARM / Plex client        ████████████████░░░░  85%
Integrity / release      ███████████████░░░░░  75%   +5  qip + post-fit oracles added
Display path (frame st.) ███████████░░░░░░░░░  55%
Shippable builds         ████████████░░░░░░░░  60%
Picture: intra (stills)  ███████░░░░░░░░░░░░░  35%  -10  HONEST CUT: not in the bitstream
Bitstream parse / CAVLC  ████████░░░░░░░░░░░░  40%
Deblocking filter        ██████░░░░░░░░░░░░░░  30%
Picture: inter / motion  ██░░░░░░░░░░░░░░░░░░  10%
                                              ─────
OVERALL                  ███████░░░░░░░░░░░░░  36%   -1
```

Intra is **cut from 45% to 35%** and the overall number goes *down*. Work that
was measured against a design the chip does not contain cannot be credited as
progress. I would rather the number move backwards honestly than forwards on a
technicality — this project's core problem has been believing its own green
checkmarks, and the percentage is not exempt from that.

### Next update

~30 minutes, leading with what is actually on your screen right now — the first
real capture of the deployed build.

---

## Update #2 — 2026-07-28 11:40 CDT (Hour 28.5)

### Headline: the new RBF is on the hardware

I verified this directly over SSH rather than trusting a worker's report:

```
/media/fat/_Utility/Plex.rbf   md5 = fb4bad849ad2db782a5004ce5a3471ce
                                     ^^^^^^^^ = fb4bad84, the authorized build
was:                           md5 = 00eebd5e   (as of update #1, 28 min ago)
```

**This is the first timing-clean build to reach real hardware.** It contains the
frame-store livelock fix and nothing else — it is a *display-path* build, not a
decode-quality build. Whether it actually produces a stable picture is being
measured now and will lead update #3.

To be explicit, because it matters: **deploy-OK is not success.** Success is
`disp_bank` toggling repeatedly, `swap_pending` returning to zero, and a
non-zero `free_bank_mask`. I will not call this working until I have that.

### The important thing that happened this half hour

**I promoted a testing rule to fleet policy, and the auditor broke it inside the
hour. It was right to.**

In update #1 I described a new reachability gate as the defence against this
project's signature failure — subsystems that pass every test but were never
connected to the product. I declared it binding across all 14 workers. The
adversarial auditor (deliberately kept on a *different* model, `gpt-5.5`) was
told to attack it. Measured result:

```
--root h264_decode_core --require h264_deblock_writeback_ctrl   rc=0   GREEN
--root emu              --require h264_decode_core              rc=1   parents=<none>
```

Read together: the deblocking filter is provably inside the decoder core, **and
the decoder core is provably not connected to the chip at all.** The gate
reported green while the thing it was gating was dead.

That is the same failure mode, for the **fourth** time — this time hiding inside
the very instrument meant to detect it. The red-proof I promoted it on was real;
my conclusion from it was too strong. **That was my error, not the worker's.**

Three more defects in the same tool, all measured:

| Mutation | Tool says | Reality |
|---|---|---|
| module inside a disabled `if (0)` block | **pass** | not instantiated |
| escaped instance name | **fail** | *is* instantiated |
| file in git but **not in the Quartus file list** | **pass** | **not in the chip at all** |

The last one is the serious one. A module can pass every check we have while not
being compiled into the bitstream. Nothing in our test suite would have noticed.

**New standard:** a subtree proof is worthless without the trunk proof — you must
show both that the module is inside the core *and* that the core reaches the top
of the chip. Plus a cross-check against the Quartus file list, and post-fit
hierarchy (what actually survived synthesis) as the only real oracle.

I have told the fleet, in writing: **when I promote a rule on thin evidence,
attack it.** A rule that dies in an hour is cheap. One that dies after another
six-hour fit is not.

### Why this is good news, not bad

Two branches each did correct work and the combination was broken — the
deblocking work landed in a core that a *different* branch had connected. Both
workers were right; the integration was wrong. That is a normal, fixable class
of problem, and we now have an instrument that finds it.

The alternative was shipping another build where everything passed and the
screen stayed black. We have done that three times. This is the first time we
caught it before the fit rather than after.

### Progress

```
ARM / Plex client        ████████████████░░░░  85%
Integrity / release      ██████████████░░░░░░  70%   +0  (gates got weaker, then honest)
Display path (frame st.) ███████████░░░░░░░░░  55%   +5  fix now RESIDENT on hardware
Shippable builds         ████████████░░░░░░░░  60%  +10  RBF delivered to device
Picture: intra (stills)  █████████░░░░░░░░░░░  45%
Bitstream parse / CAVLC  ████████░░░░░░░░░░░░  40%
Deblocking filter        ██████░░░░░░░░░░░░░░  30%   +0  sound work, disconnected core
Picture: inter / motion  ██░░░░░░░░░░░░░░░░░░  10%
                                              ─────
OVERALL                  ███████░░░░░░░░░░░░░  37%   +2
```

Still true, and the only number that counts: **zero frames have ever been
decoded and displayed by the FPGA.**

### Fleet

Migration to `claude-opus-5` essentially complete — `w-swap-o5`, `w-decode-o5`,
`w-osd-o5`, `w-deblock-o5` spawned this half hour with full written handoffs;
predecessors formally stood down with credit. `w-audit` stays on `gpt-5.5` by
design, and today is the argument for that: a same-model reviewer tends to share
the original's blind spots, and this one found four faults in an hour.

```
live on opus-5   w-arm-o5  w-gate-o5  w-fit-o5  w-swap-o5  w-decode-o5
                 w-osd-o5  w-deblock-o5
auditor gpt-5.5  w-audit
still migrating  w-cast  w-e2e
```

### Your three defects

| Defect | Owner | State |
|---|---|---|
| Cast available but play never starts, web player stuck 0:00 | `w-cast` | 2 real product bugs found; parser covers 1170/1170 MBs of a real P-frame |
| Screensaver / Plex logo black | `w-osd-o5` | respawned; told to distinguish *nothing drawn* vs *wrong address* vs *overwritten* — same symptom, three different fixes |
| Left-edge jagged black lines, moving | `w-arm-o5` | ARM fix ready, deploying **separately** from the RBF so the cause is attributable |

### Next update

~30 minutes, leading with whether `fb4bad84` produces a toggling display bank on
real hardware.

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
