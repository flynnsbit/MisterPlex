# STA Acceptance Criteria — Pre-committed Before Observation

**Author:** w-cap  
**Date:** 2026-07-27  
**Applies to:** Next provenance-correct two-slot fit after CDC integration

---

## Decision Rules (decided now, applied after fit)

### 1. Setup Slack

| Condition | Verdict |
|-----------|---------|
| All setup slack ≥ 0.000 ns | **TIMING_CLEAN** — proceed to deploy staging |
| Any setup slack < 0.000 ns but > -0.500 ns | **TIMING_MARGINAL** — report to parent, do NOT deploy. Investigate whether multicycle or pipeline fix can close the gap. Re-fit after RTL change. |
| Any setup slack ≤ -0.500 ns | **TIMING_FAIL** — hard stop. Same verdict as current -2.137 ns. No deploy. |

**Rationale:** Cyclone V timing derating and board-level variation can consume
~200-300 ps of apparent margin. A path that "barely passes" at 0.050 ns may
fail in the field. But -0.500 ns is a design error, not a marginal case.

### 2. Hold / Recovery / Removal

| Condition | Verdict |
|-----------|---------|
| Hold ≥ 0.000 ns | PASS |
| Hold < 0.000 ns | **HARD FAIL** — hold violations are uncorrectable at deployment. |
| Recovery ≥ 0.000 ns | PASS |
| Recovery < 0.000 ns | **HARD FAIL** |
| Removal ≥ 0.000 ns | PASS |
| Removal < 0.000 ns | **HARD FAIL** |

### 3. Selective Closure Scenarios

| Scenario | Verdict |
|----------|---------|
| Both PATH 1 and PATH 2 close (slack ≥ 0) | Proceed per Rule 1 |
| PATH 1 closes, PATH 2 (y_valid) still fails | **HARD FAIL** — PATH 2 is the direct stall candidate. A fit that closes PATH 1 but not PATH 2 has no diagnostic value and must not deploy. |
| PATH 2 closes, PATH 1 (current_session) still fails | **CONDITIONAL** — PATH 1 affects bitstream reader, not frame store. If PATH 1 slack is > -0.500 ns and no other paths fail, escalate to parent for decision. Do NOT deploy without explicit authorization. |
| Both paths close, but NEW negative-slack rows appear | **HOLD** — investigate new paths before any verdict. The arbiter clock-domain change reshuffles the entire DDR interface timing; new failures are not impossible. Each new path must be classified (real crossing vs. false path vs. constraint artifact) before the fit can be accepted. |

### 4. Combinational Loop Warnings (332125/332126)

| Condition | Verdict |
|-----------|---------|
| Zero 332125 warnings | PASS |
| Any 332125 warning in `async_fifo.sv` | **HARD FAIL** — the `9461845` fix must have landed. If this warning persists, the integration is incomplete. |
| Any 332125 warning in modules OTHER than async_fifo | **HOLD** — new loop, must be investigated before deploy. |

### 5. Module Resource Floors (from w-c2's hierarchy gate)

`ddr_frame_store` must survive fitting with ≥1000 ALUTs, ≥500 registers,
≥100K block memory bits. If the fitter trims it below those floors, the
module has been optimized away or the DDR_FRAME_STORE macro is not set.

### 6. Bit Identity

Two-slot fit must produce **identical md5 checksums**. Any divergence means
a non-deterministic build, and the RBF is untestable. **HARD FAIL.**

The resulting md5 must NOT be in the banned set:
`8832824e 75da8bb1 4d6ee356 4deaf6cc dabdaeb0 94bbfe43 ec21e133 eeff4eee`

### 7. Constraint Integrity

No `set_clock_groups -asynchronous` or `set_false_path` covering the
`general[0].gpll ↔ general[2].gpll` crossing may appear in any SDC file.
The `check_timing_exclusions.py` gate must pass.

---

## Summary

**A passing fit requires ALL of:**
- [ ] Setup slack ≥ 0.000 ns on all paths (Rule 1)
- [ ] Hold/recovery/removal ≥ 0.000 ns (Rule 2)
- [ ] Both PATH 1 and PATH 2 closed, or parent-authorized exception (Rule 3)
- [ ] No new negative-slack paths unaccounted for (Rule 3)
- [ ] Zero 332125 warnings from async_fifo.sv (Rule 4)
- [ ] Module resource floors met (Rule 5)
- [ ] Bit-identical two-slot md5 not in banned set (Rule 6)
- [ ] No timing exclusions hiding the clk_sys↔clk_ddr crossing (Rule 7)

**Any single failure is a HARD STOP. No partial passes. No "known warnings."**

---

## Rule 8. Intra-domain Fmax Reporting (added 2026-07-27T17:05)

The post-fit Fmax Summary contains **intra-domain** Fmax for each clock
(same-source-and-destination paths only). Report these explicitly and
separately from the headline setup slack:

| Clock | Pre-fix Fmax | Target | Pre-fix intra slack |
|-------|-------------|--------|---------------------|
| clk_sys (general[0], 20 MHz) | 25.09 MHz | 20 MHz | +10.14 ns |
| clk_ddr (general[2], 90 MHz) | 88.31 MHz | 90 MHz | −0.21 ns |

**clk_ddr is expected to worsen** after the arbiter moves into that domain.
If the cross-domain failure is eliminated but `clk_ddr` intra-domain Fmax
drops further (say to 85 MHz), that is the fix **relocating** the problem
to where it can be solved by pipelining — not the fix failing.

**Route both figures to w-arch immediately after the fit.** The `clk_sys`
intra-domain Fmax directly quantifies decode-fabric frequency headroom.

---

## Rule 9. Attribution Pre-commitment (added 2026-07-27T17:05)

Four CDC fixes land simultaneously in the integration tree:

| Fix | Commit | What it addresses |
|-----|--------|-------------------|
| Arbiter domain move (clk_sys → clk_ddr) | `60df5a2` | PATH 1 + PATH 2 timing violations |
| Response FIFO for m1_dout_ready | `3c6d1d2` | Dropped DDR read beats (11 ns pulse / 50 ns sample) |
| m1_busy 2-FF sync | `610c298` | Crossing #21, arbiter busy signal |
| want_y Gray-code CDC | `70481fd` | Crossing #13, line-cache eviction (4th stall candidate) |

**Pre-committed attribution assessment:**

If the deployed core **presents correctly** (PLXF `has_frame=1`, pixels
graded as correct):

> **The evidence will show that the set of four fixes resolved the stall.
> It will NOT isolate which fix was individually necessary or sufficient.**
>
> Specifically: there is no observation available from a single deploy that
> distinguishes "the arbiter timing violation alone caused the stall" from
> "the want_y eviction glitch alone caused the stall" from "both were
> required." All four fixes address paths that converge on the same
> observable — frame delivery — and the stall has only one symptom
> (PLXF present + has_frame=0).

**The honest label is: "four CDC defects fixed as a set; stall resolved;
individual RCA not established."** This is a legitimate engineering
outcome. Do not claim a specific root cause post-hoc.

The only way to isolate individual fixes would be to deploy them one at
a time in separate fits — four exclusive-slot builds, each consuming
hours. The parent may or may not consider that worthwhile; the decision
is theirs, not mine.

If the deployed core **still stalls** (PLXF present, has_frame=0):

> The four fixes are insufficient. At least one additional defect exists
> that was not in the set. This would be a stronger result than a pass,
> diagnostically — it eliminates four candidates and proves a fifth.

---

## Rule 10. Instrument Sanity (added 2026-07-27T17:05)

w-a3 has identified that **PLXS** (0x3007F100) and **PLXM** (0x3007F110)
mailbox CDC was unsafe prior to `70481fd`. After the fix, both use
toggle-snapshot CDC. However, as a defence-in-depth:

**When reading any mailbox for fit grading, confirm value stability:**
1. Read the register 3 times with ≥100 ms spacing.
2. If all 3 reads match → value is stable, proceed.
3. If any read differs → flag as UNSTABLE, do not use for grading.
   This would indicate a live CDC issue in the telemetry path itself.

This supplements the existing magic-check (no magic → never written).

---

## Rule 11. Plane Prediction Verification (added 2026-07-27T17:05)

Before starting the fit, confirm the integration tree contains:
- `d027c63` (pipelined I16 Plane, 2-cycle) or its successor `df21c4a`
  (balanced gradient tree, further reducing cycle 1 critical path)
- Register stages `a_r`, `bx_r[0:15]`, `cy_r[0:15]` present in source

After fit completes, check the fitter's multiplier usage for
`h264_intra16x16_pred`. If the fitter reports >50 multiplier elements
for this module, the product-sharing claim is wrong regardless of what
simulation says — flag and investigate before deploy.

**Current status:** `d027c63` verified at source level. Register stages
confirmed. Balanced tree (`df21c4a`) also verified. HOLD is conditionally
lifted — final confirmation required against the actual integration SHA.
