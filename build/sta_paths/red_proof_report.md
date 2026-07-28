# SDC Constraint Red-Proof Report

**Method:** Quartus 17.0.2 TimeQuest on slot14 netlist (post-fit). Each constraint
individually removed while all others remain active, then report_timing queried for
the specific target/source of the removed constraint.

**Baseline (all 6 constraints active):** worst setup = +0.225 ns, 0 violated paths.
**All constraints removed:** worst setup = −10.084 ns, 5 violated paths.

## Individual Results

| # | Constraint | Target | Without: Slack | Verdict |
|---|-----------|--------|---------------|---------|
| 1 | `set_false_path -to *ddr_arb\|m1_want_s1` | 2-FF sync first stage | **−4.678 ns (VIOLATED)** | ✅ RED-PROOF PASS |
| 2 | `set_false_path -to *ddr_arb\|reset_s1` | Reset sync first stage | No path found | ⚠️ PROPHYLACTIC (no-op in this netlist) |
| 3 | `set_false_path -to *m1_rsp_fifo\|wr_gray_r1[*]` | Gray write ptr sync | +1.816 ns (passes) | ⚠️ PROPHYLACTIC (met by margin) |
| 4 | `set_false_path -to *m1_rsp_fifo\|rd_gray_w1[*]` | Gray read ptr sync | +3.105 ns (passes) | ⚠️ PROPHYLACTIC (met by margin) |
| 5 | `set_max_delay -from *m1_rsp_fifo\|mem* 50.0` | FIFO RAM data path | **−10.084 ns (VIOLATED)** | ✅ RED-PROOF PASS |
| 6 | `set_false_path underrun_count→frame_mbox_last` | Diagnostic mailbox | **−0.038 ns hold (VIOLATED)** | ✅ RED-PROOF PASS |

## Load-Bearing Constraints (timing breaks without them)

**Constraint 1 — m1_want_s1:**
- Path: `ddr_stream|write_count[5]` → `ddr_arb|m1_want_s1`
- Cross-domain: general[0].gpll (20 MHz) → general[2].gpll (90 MHz)
- Slack without: −4.678 ns, data delay 9.086 ns
- Justification: 2-FF synchroniser first stage. By definition metastable-settling;
  timing analysis is meaningless for this register.

**Constraint 5 — FIFO RAM data (`set_max_delay 50.0`):**
- Path: `m1_rsp_fifo|mem~7` → `ddr_stream|consumer_seq[0..16]`
- Cross-domain: general[2].gpll (90 MHz) → general[0].gpll (20 MHz)
- Slack without: −10.084 ns, data delay 14.718 ns
- Justification: FIFO data bounded by max_delay (NOT false-pathed). Gray pointers
  guarantee reader doesn't look early; max_delay bounds propagation time. Actual data
  delay 14.718 ns is well under 50 ns limit = path is constrained AND met.
- **This is NOT a false_path.** Parent explicitly refused false_path here.

**Constraint 6 — underrun→frame_mbox_last (hold):**
- Path: `ddr_frame_store*underrun_count[*]` → `ddr_frame_store*frame_mbox_last[*]`
- Cross-domain: general[0].gpll → general[2].gpll (diagnostic mailbox CDC)
- Slack without: −0.038 ns hold violation
- Justification: Diagnostic heartbeat counter. Self-corrects every 2^18 cycles.
  Hold race on a counter that is read for telemetry only; no functional consequence.

## Prophylactic Constraints (correct but not load-bearing)

**Constraint 2 — reset_s1:**
- Keeper exists (verified) but Quartus finds NO cross-domain timing path to it.
- The reset signal feeding this synchroniser has no associated launch clock in the
  timing netlist (asynchronous reset). Constraint is structurally correct (all CDC
  first-stages should be false-pathed) but is a no-op for this placement.
- **Recommendation:** Keep it — a future placement or source change could expose the path.

**Constraints 3 & 4 — Gray pointer syncs (wr_gray_r1, rd_gray_w1):**
- Both are genuine cross-domain paths between general[0] and general[2].
- Both currently pass timing by margin (+1.816, +3.105) even without the constraint.
- **This is correct CDC engineering** — these are first-stage synchroniser registers and
  should always be false-pathed regardless of whether they happen to meet timing. A future
  placement that routes them longer would violate without the constraint.
- **Recommendation:** Keep both — they are cheap insurance against placement variation.

## Summary

- **3 of 6 constraints are timing-critical** (removing any one reopens violations)
- **3 of 6 are prophylactic** (structurally correct, not needed for THIS placement)
- **0 of 6 are incorrect** (none constrain a path that should be timed)
- Timing closure is achieved by constraints, NOT by logic changes (confirmed by −10.084 ns
  delta when constraints are removed)
- The `set_max_delay` on FIFO RAM data is particularly important: it bounds the path at
  50 ns while actual delay is 14.718 ns. This proves the data path is physically met
  while remaining CONSTRAINED (not false-pathed and forgotten).

## Wildcard Expansion Reconfirmation

`get_keepers {*ddr_arb*m1_rsp_fifo|mem*}` matches register nodes in the inferred RAM.
The −10.084 ns path runs FROM `mem~7` confirming the wildcard captures the source correctly.
