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
