# W-OSD-O5 — the `0x3007F1xx` probe window is dead on every shipping build

**Branch:** `w-osd-o5` · **Commit:** see `git log` for this file
**Status of the device:** unreachable (`192.168.1.183`, parent-confirmed). Everything
below is a **source/RTL-level determination**, not a live measurement.

## Why this is urgent

`w-fit-o5` reported, while a parent-authorized deploy waits on it:

> `0x3007F100/104/128/12C` remain dead instruments on the resident build

and separately scores the resident `fb4bad84` as **PLXD silent**, with the pending
`3b1e8435` A/B to be read as *"`3b1e8435` advances → the SDC change caused the
regression; `3b1e8435` silent → SDC exonerated"*.

**If the PLXD observation was taken at `0x3007F128`, it cannot support either
branch of that inference**, because that address is dead by construction on
every build in this project — not just on `fb4bad84`.

## Measured

Every mailbox offset is relative to a doorbell placed at

```
doorbell = PHYS_BASE + 2 * bank_stride - 0x1000
```

so the bank stride moves the **whole window**. From
`origin/parent/integ-hour27` — the branch that produced the resident
`fb4bad84`:

```
rtl/present_core.sv:252-254
        .PHYS_BASE(32'h3000_0000),
        .HPS_BANK_STRIDE_BYTES(DDR_FRAME_YUV420P_BANK_STRIDE),
        .DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)

rtl/ddr_frame_layout_params.svh:28-30
        DDR_FRAME_YUV420P_BANK_STRIDE   = 32'h0008_0000
        DDR_FRAME_YUV420P_DOORBELL_PHYS = 32'h300F_F000
```

`0x30000000 + 2*0x80000 - 0x1000 = 0x300FF000`. The header value and the
derivation agree.

| stride | doorbell | status |
|---|---|---|
| `0x40000` | `0x3007F000` | `ddram_frame_rd`'s bare **module default**. Used by **no** shipping layout family. |
| `0x80000` | `0x300FF000` | **YUV420p — this is what `fb4bad84` instantiates.** |
| `0xC0000` | `0x3017F000` | RGB565. |

**The live window for the resident build:**

```
PLXK 0x300FF000   PLXS 0x300FF100   PLXI 0x300FF108   PLXM 0x300FF110
PLXF 0x300FF118   DIAG 0x300FF120   PLXD 0x300FF128
```

## The trap, stated precisely

All three windows exist in the DDR address map, and DDR retains whatever an
older core last wrote there across a warm boot. I measured this pre-blackout:
**`0x3007F000` answers with valid, correctly-formed, frozen magics.**

So a probe at `0x3007F128` returns a plausible mailbox whose counter never
advances — which is **the same signature as a wedged present path**. It is a
false-negative generator: it reads "alive but silent" for *every* build,
unconditionally.

That is why this matters for the pending A/B specifically. If both `fb4bad84`
and `3b1e8435` are probed there, **both read silent**, the comparison
discriminates nothing, and the null result looks exactly like the "SDC
exonerated" branch of the inference. This is the same family as the vacuous
control `w-fit-o5` themselves identified — a comparison that does not actually
vary the thing it claims to test.

## What I am *not* claiming

- I do **not** know which address `w-fit-o5` used for the PLXD-silent reading.
  I am flagging a confound, not asserting an error. If it was taken at
  `0x300FF128`, the observation stands untouched and this note costs nothing.
- The statement *"`0x3007F1xx` are dead instruments"* is **correct**. Only the
  inference "…on the resident build" is unsafe: they are dead on all builds, so
  their deadness carries no information about `fb4bad84`.
- The device is down, so none of this is a live re-measurement.

## Remedy shipped

`scripts/mailbox_window.py` derives the window from the RTL rather than
hardcoding it, and names the dead windows explicitly so they are not mistaken
for evidence:

```
python3 scripts/mailbox_window.py --project fpga/Plex_MiSTer --devmem
```

It refuses rather than guesses when the instantiated family is ambiguous or
absent, and cross-checks the header doorbell against
`PHYS_BASE + 2*stride - 0x1000`.

**That cross-check immediately caught a bug in my own parser.** `32'h0008_0000`
is all-digits, so an `isdigit()` radix test read it as decimal `80000`, yielding
`0x13880` and a doorbell of `0x30026100`. The redundant derivation is the only
reason it did not ship. It is now a permanent regression case (`red1`).

## Gate and its reds

`tests/unit/test_mailbox_window.sh` — 16 assertions, wired into `make unit`
(`unit-rollcall` 91 → 92 protected commands). Hermetic synthetic fixtures, plus
a bonus assertion against `origin/parent/integ-hour27` that does **not** skip
the suite when the branch is unfetched.

Red-proven by injecting two real defects and confirming the suite fails:

| injected defect | result |
|---|---|
| original `isdigit()` radix bug | **rc=1**, 6 assertions flip |
| "helpful" fallback family instead of refusing | **rc=1**, red3/red4 flip |

`make unit` → **rc=0**, log contains `MAILBOX_WINDOW_RESULT=PASS` (confirmed the
gate actually executes and is not merely registered).

## Ask

`w-fit-o5`: state which address the PLXD reading was taken at. If
`0x3007F128`, re-take at `0x300FF128` before the deploy is scored — otherwise
the A/B produces a confident null.

---

## Addendum — the merge base is very likely how the dead address was obtained

Measured on `w-osd-o5-hour27` (based on the mandated merge base
`w-decode-hour27` `2f165ed`), **before** this commit:

```
host/libmisterplex/mailbox_abi_spec.hpp
  kPlxkAddr      0x3007F000    kPlxsAddr  0x3007F100
  kPlxiAddr      0x3007F108    kPlxmAddr  0x3007F110
  kPlxfAddr      0x3007F118    kSdramDiagAddr 0x3007F120
  kPlxdAddr      0x3007F128
```

That is the **entire** mailbox address content of the canonical ABI header on
the branch all product work is being rebased onto. There were **no**
`kYuv420p*` constants and **no** warning that this block is the dead
`0x40000`-stride window.

So anyone reading the project's own ABI header on the merge base gets
`0x3007F100/0x3007F128` as the addresses to probe, with nothing to suggest
otherwise. **This is the most likely provenance of the reported
`0x3007F100/104/128/12C` probe, and it is a documentation defect, not a
reasoning error by whoever used it.**

Fixed here by porting the documented superset (the two versions diff to a strict
subset — 0 lines were unique to the merge base, so the copy is lossless):
the dead-window banner, the `kYuv420p*` live constants, `doorbellForStride()`,
and four `static_assert`s that tie the literals to the stride arithmetic.
Compile-checked: `g++ -fsyntax-only -std=c++17` → rc=0, all static asserts hold.

The instantiated window on the merge base is **identical** to the deployed
branch (`YUV420P`, stride `0x80000`, doorbell `0x300FF000`), so a fit from
`w-decode-hour27` publishes on the same addresses — the probe target does not
change.

---

## Addendum 2 — an existing gate caught this tool hardcoding the very literals it exists to derive

`make unit` went **rc=0 → rc=2** the moment `scripts/mailbox_window.py` was
committed:

```
FAIL: runtime DDR frame layout literals must route through ddr_frame_layout derivation;
  found scripts/mailbox_window.py:13: stride 0x40000 -> 0x3007F000 ...
        scripts/mailbox_window.py:15: stride 0x80000 -> 0x300FF000
```

`check_runtime_ddr_layout_literal_sweep` (`tests/unit/test_rtl_invariants.py`)
was right. The script *computes* every address it prints, but its **docstring**
spelled the doorbells as literals — a tool whose entire purpose is "derive, do
not hardcode" hardcoded them in its own documentation. Fixed by describing the
strides and deferring the values to `ddr_frame_layout_params.svh` /
`mailbox_abi_spec.hpp`, which the gate designates as the single source of truth.
Offenders now 0; `make unit` rc=0 with `MAILBOX_WINDOW_RESULT=PASS`.

### The transferable trap

**A `make unit` green taken before `git add` is not predictive.** That sweep
walks `tracked_product_relevant_files()` — tracked files only, deliberately, so
untracked scratch does not trip it (there is an explicit test for that
behaviour). I ran `make unit` with this script present and untracked, got rc=0,
and the file was invisible to the gate. The identical tree went rc=2 once
committed.

So for any gate that scans tracked files, the green that counts is the one
**after** staging. Worth folding into the standard alongside "a skip is not a
pass": *a green over an empty or truncated scope is not a pass either* — the
same `Scope: 0` vacuity family already flagged fleet-wide.

---

## Addendum 3 — a hypothesis of mine, refuted by my own measurement

**Hypothesis (mine, now REFUTED).** The parent's re-authorized A/B rests on
`00eebd5e` reading *PLXD advancing ~68/s* and `fb4bad84` reading *PLXD silent*.
I proposed that the older build predated the doorbell move, so `0x3007F128`
would have been *live* for `00eebd5e` and *dead* for `fb4bad84` — making the
whole difference an instrumentation artifact.

The motivation was real. `ddram_frame_rd.sv` before `a6ec399` documented:

```
Bank 1: 0x30040000  (256 KiB stride; frame is 153600 B)
Doorbell: 0x3007F000
```

So `0x3007F000` genuinely *was* the live doorbell at one point, which is why
stale magics sit there today.

**Measured refutation.** `00eebd5e` is the `wtime4` fit, fitted HEAD `e1dffa3`
(2026-07-28 01:40). `a6ec399` (2026-07-26 23:05) is an **ancestor** of it
(`git merge-base --is-ancestor` → true). Resolving `e1dffa3`'s own tree:

```
instantiated layout family : YUV420P
bank stride                : 0x00080000
doorbell                   : 0x300FF000
```

**Both builds publish on the same window.** My hypothesis is dead. The
instrument did not change meaning between the two arms.

## What survives, and it is sharper

Both builds reject `0x3007F128` (`PROBE_WINDOW_FAIL`, rc=1). A dead window is
**frozen** — so it *cannot* advance. Therefore:

- *"`00eebd5e` PLXD advancing ~68/s"* **can only have come from `0x300FF128`.**
  A positive reading authenticates its own instrument.
- *"`fb4bad84` PLXD silent"* is compatible with **both** a wedged live window
  **and** any dead window. It authenticates nothing.

And `w-fit-o5` explicitly cites probing `0x3007F100/104/128/12C`. If the
"silent" arm came from there while the "advancing" arm necessarily came from
`0x300FF128`, **the two arms of the A/B were read at different addresses.**
Unverified — the device is offline and I do not have their command — but it is
the one remaining way this experiment returns a confident wrong answer.

### The general principle — the asymmetric-null rule

This is a distinct member of the parent's vacuous-control family, and worth
stating separately because the mechanical test differs:

> **A positive result can validate its own instrument. A null result never
> does.** Any claim of the form *silent / absent / dead / no signal / zero
> frames* must carry independent proof that the instrument could have shown
> otherwise.

The parent's rule asks *"does this comparison vary the thing it claims to
test?"* — a property of the **design**. This one asks *"could this measurement
have come out differently?"* — a property of the **null arm specifically**. A
comparison can vary its independent variable correctly and still be void
because only its negative arm was mis-instrumented.

Note how much of this project's history is null claims: `h264_decode_core`
ABSENT, PLXD silent, `IDLE_SCREEN=black`, zero frames decoded. Each one needs
its instrument proven live, separately from the comparison being well-designed.

## Mechanised

`--probed ADDR` (repeatable) validates any address a report cites against the
build under test, so this stops being a thing anyone has to remember:

```
$ mailbox_window.py --project <fb4bad84 tree> --probed 0x3007F128
  FAIL 0x3007F128  PLXD is in the DEAD window 0x3007F000 (stride 0x40000);
                   this build publishes PLXD at 0x300FF128
PROBE_WINDOW_FAIL ...                                              rc=1

$ mailbox_window.py --project <fb4bad84 tree> --probed 0x300FF128
  OK   0x300FF128  PLXD in the live YUV420P window
PROBE_WINDOW_OK                                                    rc=0
```

Suite now 24 assertions. Red-proven by injecting a validator that accepts any
address: **rc=1, 7 assertions flip**. `make unit` rc=0,
`MAILBOX_WINDOW_RESULT=PASS`, literal-sweep offenders 0.

---

## Addendum 4 — my own mode-3 evidence was unbound, and read the wrong build

The parent's ruling *"an unbound report must be UNBOUND, never a pass"* landed
on `check_build_id_delivery.py --fit-rpt`, which is mine.

**What was wrong, measured:**

1. **No binding at all.** It accepted any report path. I had cited
   `remote_out/deploy2/Plex.fit.rpt` — RBF md5 **`8eb01b79`**, which is **not**
   the resident `fb4bad84`. My claim *"the build ID is not a mode-3 casualty"*
   was drawn from a build nobody is running. **55 fit reports exist in this
   worktree**; the parent counted 40 and either way the wrong-report hazard is
   real.
2. **It conflated absent with unseen.** Given a report it could not parse as a
   product hierarchy, it printed *"the OSD render path was optimized away"*.
   Demonstrated by injection against a two-line fake report:
   ```
   FAIL hps_io is absent ... the OSD render path was optimized away
   FAIL osd    is absent ... the OSD render path was optimized away
   ```
   Neither statement was about the design. Both were about my parser. This is
   exactly `w-arm-o5`'s formulation — *a self-imposed scope limit silently
   became a claim about the world*.

**Fixed, matching `check_fitted_line_buffer.py`'s convention rather than
inventing a second one:** `--expect-rbf-md5` binds to a sibling `Plex.rbf`;
unbound returns **77** and prints **no verdict line**, so nothing can grep
`BUILD_ID_DELIVERY OK` out of a run that proved nothing. An `emu` anchor
distinguishes the two failures: no anchor → **UNSEEN, rc=2**, never
"optimized away".

**Re-measured, properly bound to the bitstream the user is looking at:**

```
BOUND report -> Plex.rbf md5=fb4bad84
Scope: 133 distinct modules in Plex.fit.rpt, anchor emu present
OK survived synthesis: hps_io
OK survived synthesis: osd
BUILD_ID_DELIVERY OK                                              rc=0
```

**The conclusion survives** — the OSD render path is not a mode-3 casualty in
the resident silicon — but it is only now that it rests on the right report.
This also independently corroborates the parent's finding that the display path
survives fitting: same report, different modules.

Reds added (suite 38 → 48 OK lines): unbound → 77 with **no verdict line**;
wrong md5 → `BINDING_FAIL`; `--expect` with no sibling RBF → fail; unreadable
hierarchy → `UNSEEN` rc=2 and **must not** say "optimized away"; plus a
resident-bound bonus green. Red-proven by injecting "unbound reports are
accepted": rc=1, 2 assertions flip. `make unit` rc=0.
