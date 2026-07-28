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
