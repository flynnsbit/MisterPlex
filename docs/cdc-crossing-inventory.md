# MiSTerPlex CDC Crossing Inventory

**Owner:** w-a3 (DDR frame store, async FIFOs, clock-domain crossing, deblocking)
**Date:** 2026-07-27 (updated 2026-07-29)
**Branch:** `feat/a3-frame-store` @ `7e3fc41`
**Scope:** All crossings between `general[0].gpll` (clk_sys, 20 MHz) and
`general[2].gpll` (clk_ddr, 90 MHz) in the DDR presentation and streaming paths.

### ⚠️ Enumeration method and completeness

This inventory was **hand-enumerated from RTL source** by reading every signal
whose driver and receiver sit in different clock domains. The list of 30 crossings
is a true statement about 30 crossings found by reading; **it is not proven
complete.**

A mechanical derivation — `quartus_sta Plex --report_clock_domain_crossings` —
would catch crossings through instantiated IP, inferred latches, and combinational
paths spanning domains without an explicit flop that source reading structurally
cannot see. This has been requested from w-cap as part of the next fit. When that
report lands, this inventory will be reconciled against it and either upgraded from
*enumerated* to *derived*, or extended with any gaps found.

**Until reconciliation: "30/30 SAFE" means 30 hand-found crossings are safe, not
that all crossings in the design are safe.**

---

## Clock domains

Both clocks originate from the same PLL (`pll_0002.v`) with 0 ps phase shift.
Quartus treats them as synchronous and times crossings with a 5.555 ns setup
relationship (clk_sys→clk_ddr) or ~44 ns (clk_ddr→clk_sys).

| Domain | Signal | Frequency | PLL output | STA clock |
|--------|--------|-----------|------------|-----------|
| clk_sys | `clk_sys` | 20.000 MHz | `outclk_0` | `general[0].gpll` |
| clk_ddr | `clk_ddr` / `DDRAM_CLK` | 90.000 MHz | `outclk_2` | `general[2].gpll` |

---

## Doctrine (learned at cost on this project)

### 1. A 2-FF synchronizer on multi-bit data is unsound

`audio_fifo.sv` passed 12-bit binary write/read pointers through 2-FF synchronizers
for the entire life of this project. Multiple bits changing simultaneously can be
sampled mid-transition, producing a pointer value that never existed. Fix: Gray-coded
pointers where only one bit changes per increment. Commit `d86c183`.

**Rule:** The only safe multi-bit CDC mechanisms are:
- Gray-coded async FIFO (`async_fifo.sv`)
- Dual-port RAM with separate clock ports (M10K `line_buf_ram`)
- Protocol-guarded multi-bit signals (held stable for multiple destination cycles
  before a single-bit enable/toggle crosses)

### 2. A single-cycle fast→slow pulse is silent data loss that STA reports as clean

`m1_dout_ready` was a single clk_ddr pulse (11.1 ns) sampled by the clk_sys consumer
(50 ns period). **Beat conservation test measured 7 of 10 CAS latencies dropping the
beat** — the consumer missed the pulse entirely. STA reported the path as timing-clean
because the signal met setup/hold at the destination register; it simply was not high
when the destination sampled. Fix: `async_fifo` on the response path. Commit `3c6d1d2`.

**Rule:** Fixed relative clock rates are not a substitute for a handshake or a FIFO.
Static timing analysis structurally cannot see this class of fault. **Beat conservation
is the test that catches it** — count beats issued by the producer against beats accepted
by the consumer. If they are not equal, data is being dropped.

### 3. Our gate suite cannot catch pulse-drop faults

The project has a substantial gate suite: `rtl-lint`, `quartus-sv-subset`,
`define-parity`, `post-fit-hierarchy`, `post-fit-timing`, `timing-exclusion`,
`confstr-guard`, `test_rtl_invariants.sh` (20 checks), and an anti-evasion timing gate.
**None of these could have caught a bug that dropped 70% of memory beats.** Only a
purpose-built beat conservation count found it. This is not a deficiency in the gates —
it is a structural limitation of static analysis. Pulse-drop faults require simulation
with dual-domain counters.

### 4. "It appears to work" is the most dangerous state

The audio FIFO appeared to work. The arbiter on the wrong clock appeared to work.
`m1_busy` as an unsynchronized combinational crossing appeared to work. In each case
"appears to work" meant "the failure is intermittent, data-dependent, and
indistinguishable from a decode bug." A warning present long enough to be called
"known" is the most dangerous kind.

---

## Beat conservation test pattern (reusable)

For any fast→slow crossing carrying pulsed data:

```systemverilog
// Producer side (fast clock):
integer wr_beats = 0;
always @(posedge clk_fast)
    if (producer_valid) wr_beats = wr_beats + 1;

// Consumer side (slow clock):
integer rd_beats = 0;
always @(posedge clk_slow)
    if (consumer_valid) rd_beats = rd_beats + 1;

// After workload completes:
// assert(wr_beats == rd_beats)
// If not equal, beats are being dropped.
```

Vary the phase relationship or CAS/response latency across runs to exercise all
possible alignments of the fast pulse within the slow sampling window. A test that
passes at one latency and fails at another proves the crossing is alignment-dependent.

See `rtl/tb_arb_beat_conservation.sv` for the reference implementation.

---

## Crossing table

### ddr_frame_store.sv (clk ↔ clk_ddr)

| # | Signal | Dir | Width | Type | Mechanism | Verdict |
|---|--------|-----|-------|------|-----------|---------|
| 1 | `reset` | clk→clk_ddr | 1 | level | 2-FF async reset sync (`reset_ddr_s1/s2`) | SAFE |
| 2 | `swap_req_t_ddr` | clk→clk_ddr | 1 | toggle | 2-FF sync (`swap_req_s1/s2`) + toggle protocol | SAFE |
| 3 | `pending_bank_ddr` | clk→clk_ddr | 1 | level | 2-FF sync (`pending_bank_s1/s2`), stable before toggle fires | SAFE |
| 4 | `pending_ready_ddr` | clk→clk_ddr | 1 | level | 2-FF sync (`pending_ready_s1/s2`) | SAFE |
| 5 | `disp_bank` | clk_ddr→clk | 1 | level | 2-FF sync (`disp_bank_d1/d2`) | SAFE |
| 6 | `disp_buf` | clk_ddr→clk | 1 | level | 2-FF sync (`disp_buf_d1/d2`) | SAFE |
| 7 | `has_frame` | clk_ddr→clk | 1 | level | 2-FF sync (`has_frame_d1/d2`) | SAFE |
| 8 | `swap_pending` | clk_ddr→clk | 1 | level | 2-FF sync (`swap_pending_d1/d2`) | SAFE |
| 9 | `pending_bank` | clk_ddr→clk | 1 | level | 2-FF sync (`pending_bank_d1/d2`) | SAFE |
| 10 | `vsync_toggle` | clk→clk_ddr | 1 | toggle | 2-FF sync (`vsync_t_d1/d2`) + toggle protocol | SAFE |
| 11 | `start_req` | clk→clk_ddr | 1 | toggle | 2-FF sync (`start_d1/d2`) + toggle protocol | SAFE |
| 12 | `bank_sel` | clk→clk_ddr | 1 | level | 2-FF sync (`bank_sel_d1/d2`), stable before start toggle | SAFE |
| 13 | `want_y` | clk→clk_ddr | 9 | multi-bit | Gray-coded 2-FF sync (`want_y_gray` → `want_y_gray_s1/s2` → `y_gray2bin`) | SAFE (fixed: was 1-FF binary sync, `want_y_s2` dead code) |
| | | | | | **⚠ PRECONDITION:** Gray coding is safe only because `want_y_sys` increments by exactly 1 per scan line (one bit changes per transition). If `want_y` ever jumps by >1 (seek, resolution change, fast-forward), multiple Gray bits change simultaneously and the protection silently breaks. **Enforced** by `$error` assertion in RTL (`ifdef VERILATOR`). | |
| 14 | `status_osd` | clk→clk_ddr | 16 | multi-bit | Toggle-snapshot (`status_osd_toggle` 2-FF sync, data captured on edge) | SAFE (fixed: was 2-FF binary sync, fed PLXS mailbox) |
| | | | | | **⚠ INSTRUMENT-INTEGRITY:** This feeds the PLXS mailbox at `0x3007F100`, read to evaluate whether a fit succeeded. Before the fix, a glitched sample would produce a plausible-looking status word with no way to distinguish it from a real one. This is the 15th instrument-integrity failure of this session: our measuring equipment fails more often than our design does. | |
| 15 | `sdram_status` | clk→clk_ddr | 24 | multi-bit | Toggle-snapshot (`sdram_status_toggle` 2-FF sync, data captured on edge) | SAFE (fixed: was 2-FF binary sync, fed PLXM mailbox) |
| | | | | | **⚠ INSTRUMENT-INTEGRITY:** This feeds the PLXM mailbox at `0x3007F110`. A glitched `sdram_status` could falsely report SDRAM errors during fit evaluation, sending the fleet down a false debugging path for a day, or worse — read a plausible zero and trust it. Same class of failure as the `ERR=0x00000001` uninitialised-register incident. | |
| 16 | `input_fifo` data | clk→clk_ddr | 8 | data stream | `async_fifo` Gray-coded, AW=2 (4 deep) | SAFE |
| 17 | line_buf_ram ×48 | clk_ddr→clk | 64 | data | Dual-port M10K, wr_clk=clk_ddr, rd_clk=clk | SAFE |

### ddr_bus_arbiter.sv (clk_ddr ↔ clk_sys via clk_m1)

| # | Signal | Dir | Width | Type | Mechanism | Verdict |
|---|--------|-----|-------|------|-----------|---------|
| 18 | `reset` | clk_sys→clk_ddr | 1 | level | 2-FF async reset sync (`reset_s1/s2`) | SAFE |
| 19 | `m1_want` | clk_sys→clk_ddr | 1 | level | 2-FF sync (`m1_want_s1/s2`) | SAFE |
| 20 | `m1_rd/wr/addr/burstcnt/din/be` | clk_sys→clk_ddr | ~110 | multi-bit | Protocol-guarded: held stable while `m1_busy` deasserted, 50ns pulse captured by 11ns sampler | SAFE |
| 21 | `m1_busy` | clk_ddr→clk_sys | 1 | level | Registered on clk_ddr + 2-FF sync to clk_m1 (`m1_busy_r/s1/s2`) | SAFE (fixed `610c298`, was UNSAFE) |
| 22 | `m1_dout[63:0]` | clk_ddr→clk_sys | 64 | data | `async_fifo` Gray-coded, AW=3 (8 deep), auto-pop | SAFE (fixed `3c6d1d2`) |
| 23 | `m1_dout_ready` | clk_ddr→clk_sys | 1 | pulse (was) | `async_fifo` !empty on clk_m1 side — now a level signal | SAFE (fixed `3c6d1d2`) |
| 24 | `m0_dout_ready` | clk_ddr→clk_ddr | 1 | pulse | Same domain — not a crossing | N/A |
| 25 | `m0_dout[63:0]` | clk_ddr→clk_ddr | 64 | data | Same domain — not a crossing | N/A |

### audio_fifo.sv (wr_clk ↔ rd_clk)

| # | Signal | Dir | Width | Type | Mechanism | Verdict |
|---|--------|-----|-------|------|-----------|---------|
| 26 | Write pointer | wr_clk→rd_clk | AW+1 | counter | Gray-coded, 2-FF sync | SAFE (fixed `d86c183`, was UNSAFE: binary pointers) |
| 27 | Read pointer | rd_clk→wr_clk | AW+1 | counter | Gray-coded, 2-FF sync | SAFE (fixed `d86c183`, was UNSAFE: binary pointers) |

### async_fifo.sv (shared module, all instances)

| # | Instance | Location | wr_clk | rd_clk | Mechanism | Verdict |
|---|----------|----------|--------|--------|-----------|---------|
| 28 | `input_fifo` | ddr_frame_store:441 | clk | clk_ddr | Gray-coded, AW=2 | SAFE |
| 29 | `cmd_fifo` | frame_store:127 | clk | clk_sdram | Gray-coded, AW=variable | SAFE |
| 30 | `m1_rsp_fifo` | ddr_bus_arbiter:118 | clk_ddr | clk_m1 | Gray-coded, AW=3 | SAFE |

---

## Summary

| Status | Count | Details |
|--------|-------|---------|
| SAFE | 30 | All crossings properly synchronized |
| UNSAFE (fixed this session) | 7 | #13 want_y (Gray-coded), #14 status_osd (toggle-snapshot), #15 sdram_status (toggle-snapshot), #21 m1_busy, #22-23 m1_dout/ready, #26-27 audio_fifo pointers |
| N/A (same domain) | 2 | #24-25 m0_dout/ready |

**30 crossings total. All 30 proven safe. 7 were genuinely unsafe and are now fixed.**

---

## Future crossings (if a dedicated decode clock is added)

See the architecture assessment provided to w-arch. A `clk_decode` (40-45 MHz) would
require approximately:
- 5-6 new async FIFOs (~780 ALMs, 1.9% of Cyclone V 5CSEBA6)
- ~10 new 2-FF synchronizers
- ~66 ns per DPB read overhead (2 clk_decode + 2 clk_ddr sync cycles)
- The `m1_busy` crossing (#21) would become a three-way crossing if shared,
  but this is now properly registered and synchronized.

---

## Glitch injection test: want_y as frozen-screen RCA candidate

**Result: NEGATIVE.** A corrupted `want_y` does not reproduce the frozen screen.

Crossing #13 (`want_y`) had a real defect: single-sync stage with `want_y_s2` as dead
code, meaning metastability had no second stage to resolve. The parent promoted it as a
frozen-screen RCA candidate because "wrong pixels or a stall" matches the silicon
signature (`PLXF` present, `seq=4`, `has_frame=0`).

### Raw bench data

Bench: `tests/rtl/test_want_y_glitch.sh` — injects a corrupted value (offset by
`FRAME_H/2`) into `want_y_gray_s2` via Verilator rootp access before each posedge
`clk_ddr`, at configurable rates.

| Configuration | Glitch count | has_frame % | Underruns | frames_done |
|---------------|-------------|-------------|-----------|-------------|
| Baseline      | 0           | 100.0%      | 8,752     | 1           |
| Rate 37       | 2,023       | 100.0%      | 11,543    | 1           |
| Rate 5        | 14,976      | 100.0%      | 45,005    | 1           |
| Rate 1 (every cycle) | 74,880 | 100.0%   | 65,535    | 1           |

### Interpretation

1. **The injection is effective.** Underruns scale monotonically with glitch rate
   (8,752 → 65,535 at saturation), confirming the corrupted `want_y_gray_s2` is
   reaching `desired_y_r` and causing wrong line evictions/fetches.

2. **`has_frame` is structurally insensitive to `want_y` corruption.** Even at rate=1
   (every cycle corrupted), `has_frame` stays at 100%. The `pending_ready_ddr` mechanism
   at vsync recovers because DDR fetch latency is short relative to frame period.

3. **Demoted back to hygiene.** The want_y single-sync bug causes increased underruns
   (wrong pixels) but is **not** the frozen-screen root cause. The remaining candidates
   are the async-FIFO comb loop (`7a3d960`) and the arbiter→`y_valid[7]` timing path —
   both of which ride on the next fit.

---

## STA-reported violation: `disp_buf_d2 → DDRAM_ADDR` (clk_ddr intra-domain)

**Result: NEGATIVE.** Not the frozen-screen RCA.

```
FROM:   ddr_frame_store|disp_buf_d2
TO:     ddr_frame_store|DDRAM_ADDR[9]  (also [15], [18], [23], ...)
slack:  -0.213 ns    data delay 10.722 ns    7 logic levels
```

The path goes: `disp_buf_d2` → `cur_base_idx/prep_base_idx` (MUX) → cache slot
array index → hit/miss logic → `need_y_cur_c/prep_c` → MUX for `fill_bank` →
`fill_bank_base` → `y_addr/chroma_addr` → `line_addr` → `DDRAM_ADDR`.

### Why it cannot produce has_frame=0

1. **Self-consistency of prep path.** Both `pending_ready_c` (the check) and the
   prep-line fill use `prep_base_idx` derived from the same `disp_buf_d2`. Even if
   `disp_buf_d2` holds the wrong value, the fill writes to the same slots that the
   check examines. They always agree → `pending_ready` converges to 1.

2. **`has_frame` is monotonic.** The clk-domain `has_frame` register is only SET
   (at vsync when `swap_pending && pending_ready_s2`), never cleared except by reset.
   Once the first frame succeeds, subsequent `disp_buf_d2` timing violations cannot
   un-set it.

3. **No interaction with PLXD bank-release.** The PLXD mailbox uses `disp_bank_d2`
   and `pending_bank_d2` (separate 2-FF sync chains). `disp_buf_d2` controls line
   cache SET selection, not DDR BANK selection.

### Required fix (for timing closure, not for the stall)

One pipeline register stage between `disp_buf_d2` and the array index logic.
Cost: ~1-3 ALMs, 1 cycle latency on cache-set selection after bank swap.
This eliminates the 7-level combinational depth, giving ~5 ns margin at 90 MHz.

---

## Gate Assertion Audit (instrument-integrity #16 response)

**Directive:** "Open your gate. Find the line that decides pass or fail. Read exactly
what it compares — not what the test is named, not what the report says."

### Gate 1: `test_ddr_frame_store_warm_reset.sh` (Verilator simulation)

**What it literally compares:**
- `expectFreshSample()`: `top.rd_r` (luma pixel output at position 0,0) vs expected Y value, tolerance ±1.
- `sampleRgb()` at select positions: `top.rd_r`, `top.rd_g`, `top.rd_b` vs expected YUV→RGB conversion.
- `has_frame` flag convergence within N cycles.
- Doorbell acceptance/rejection logic (stale, non-YUV, equal-token).
- `schedulerProven()`: observed both `sched_valid` and a scheduled line-read.

**What it does NOT cover (that a reader would reasonably assume):**
1. **All pixel data is spatially uniform.** Every `fillFrame()` writes the same Y value
   to every pixel. A stride error that reads line N+1 instead of line N produces the
   SAME value — the test cannot detect it. Only chroma vertical stride uses varying
   data (3 distinct U rows).
2. **Single-pixel sampling at (0,0).** Only `runChromaVerticalStrideMapping` samples at
   multiple Y positions. Horizontal addressing is never tested beyond x=0.
3. **Bench parameterization (80×48) ≠ production (640×480).** Address arithmetic wraps
   at 16-bit boundaries differently. The 64KB bank stride in the bench vs 460KB in
   production exercises different address MSBs.
4. **Static single-frame presentation.** No test presents a sequence of different frames
   in real-time with concurrent display scanning — the race between producer write and
   display read is never exercised.
5. **No DDR latency variation.** The DDR model responds in fixed 4-cycle latency. Real
   SDRAM has refresh pauses (7.8 µs/row) and priority arbitration stalls not modeled.

**Can it fail?** Yes — 6 deliberate-fault red checks pass (stale doorbell, non-YUV format,
U/V plane swap, chroma vertical full-res, chroma luma-stride, disabled scheduler).
Confirmed by the shell script running each fault build and verifying non-zero exit.

### Gate 2: `test_rtl_invariants.py` (source-level text matching)

**What it literally compares (for my modules):**
- `check_async_fifo_write_full_no_comb_loop`: normalized source contains
  `wr_full_now=(wr_gray==wr_gray_full)` and `wr_accept=wr_en&&!wr_full_now`.
- `check_frame_store_cdc_contract`: normalized `ddr_frame_store.sv` contains 7 specific
  CDC pattern strings (reset sync, FIFO domain assignments, swap toggle, pending_ready
  sync, RAM clock assignments). Plus: async_fifo has Gray-coded pointer crossing text;
  SDC has no false/multicycle paths on frame-store signals.
- `check_ddr_frame_store_yuv_read_contract`: normalized source contains 17 address/stride
  expressions matching the I420 layout. Red-proven by U/V swap, coefficient swap, and
  chroma-geometry mutation.
- `check_ddr_bank_handoff_contract`: 16 ARM+RTL doorbell protocol expressions present.
  Red-proven by removing reuse-wait, reordering doorbell writes, splitting token reader.

**What it does NOT cover:**
1. **Semantic equivalence.** A source refactor using different variable names but identical
   logic will FAIL the gate (false negative). It matches text patterns, not behavior.
2. **Elaboration-time connectivity.** It verifies that sync flop *declarations* exist in
   source but cannot verify they are *connected to the correct signals* after synthesis.
3. **No simulation.** A logic bug that satisfies all pattern matches is invisible. Example:
   if `wr_gray_full` were computed incorrectly but its declaration matched the pattern,
   the gate would pass.
4. **CDC crossing #13 (want_y Gray-code):** The invariant checks that Gray crossing text
   exists but does NOT verify the Gray-code precondition (max Δ=1). That is only enforced
   by the Verilator bench assertion at runtime.

**Can it fail?** Yes — each structural check has explicit red-proofs via source mutation.
If any required pattern is removed or changed, the gate exits non-zero immediately.

### Gate 3: `test_want_y_glitch.sh` (Verilator glitch injection)

**What it literally compares:**
- Baseline run: `has_frame_cycles > 0` within measurement window (healthy = exit 0).
- Fault run: same metric after injecting corrupted `want_y_gray_s2` every ~37 cycles.
- Shell compares exit codes: both 0 → "not RCA"; baseline 0 + fault non-zero → "reproduces".

**What it does NOT cover:**
1. **Pixel correctness.** Even in "HEALTHY" verdict, pixels may be wrong — only `has_frame`
   convergence is measured, not whether the displayed frame contains correct data.
2. **Bench parameterization:** FRAME_H=48 (Y_W=6 bits). Production FRAME_H=480 (Y_W=9 bits).
   Gray code wrapping behavior differs at wider bit widths.
3. **The test_want_y_glitch.sh script ALWAYS exits 0** regardless of verdict. It is a
   diagnostic tool, not a regression gate. A fault that reproduces the stall does not
   cause CI failure.

**Can it fail?** The C++ binary exits non-zero on stall/degradation. The shell wrapper
does not propagate this as a gate failure — it reports the finding but exits 0.
**This is intentional** (investigation tool), but a reader of the script name would
reasonably expect it to be a gate.

### Gate 4: `ddr_frame_store_bank_glitch_tb.cpp` (Verilator timing violation injection)

**What it literally compares:**
- Phase 1: `has_frame` asserted within 200k cycles (first frame acquired).
- Phase 2: after injecting N-cycle hold on `disp_buf_d2` during bank swap, measures
  `has_frame` stability over observation window.

**What it does NOT cover:**
1. **Same as Gate 3:** pixel correctness not checked, bench-scale only.
2. **No runner script enforces it as a gate.** There is no `test_bank_glitch.sh` — the
   C++ binary must be invoked manually or through the want_y build infrastructure.

**Can it fail?** Yes — exits non-zero if `has_frame` never asserts in Phase 1 (infrastructure
failure). But the Phase 2 negative result (healthy after glitch) means the *designed* fault
cannot trigger failure. This was the correct scientific outcome — not a gap.

### Gate 5: `test_ddr_frame.sh` (hardware integration — w-cap only)

**What it literally compares:**
- `push_frame --status` output grepped for `has_frame=1` and DDR push OK string.
- This is a device-side smoke test — it confirms DMA reach, not pixel correctness.

**What it does NOT cover:**
1. Visual output is not captured or compared — only the status mailbox is read.
2. Only exercises 320×240 resolution, not 640×480 production.
3. Requires live MiSTer hardware — cannot run in CI.

**Can it fail?** Yes — grep failures exit non-zero. But it cannot detect wrong pixels.

---

### Summary of gaps (headline)

| Gate | Headline gap |
|------|-------------|
| warm_reset | ~~Uniform pixel fill masks stride bugs~~ FIXED: per-line Y fill added |
| rtl_invariants | Source text match ≠ behavioral correctness; refactors break it |
| want_y_glitch | Diagnostic only — always exits 0; no pixel check |
| bank_glitch | No runner script; no pixel check |
| test_ddr_frame.sh | Status-only; no visual capture |

**Biggest risk (same species as #16):** The warm_reset bench could pass with a luma
stride error because `fillFrame(bank, 208)` writes 208 to every line. A non-uniform
fill pattern (different Y per line) would catch this class of bug and costs ~5 lines
of code.

---

## Changelog

| Date | Commit | Change |
|------|--------|--------|
| 2026-07-27 | `d86c183` | audio_fifo: binary→Gray-coded pointer CDC |
| 2026-07-27 | `60df5a2` | ddr_bus_arbiter: moved from clk_sys to clk_ddr |
| 2026-07-27 | `3c6d1d2` | ddr_bus_arbiter: added m1 response FIFO (beat-drop fix) |
| 2026-07-27 | `610c298` | ddr_bus_arbiter: registered + 2-FF sync on m1_busy |
| 2026-07-27 | `70481fd` | ddr_frame_store: Gray-coded want_y (#13), toggle-snapshot status_osd/sdram_status (#14-15) |
| 2026-07-28 | — | Glitch injection test: want_y NOT the frozen-screen RCA (has_frame unaffected even at rate=1) |
| 2026-07-28 | — | Added Gray-code precondition assertion (enforced in Verilator) |
| 2026-07-28 | — | Documented instrument-integrity risk on #14, #15 |
| 2026-07-28 | — | Bank-swap timing test: disp_buf_d2 → DDRAM_ADDR NOT the frozen-screen RCA (self-consistent prep path) |
| 2026-07-28 | — | Gate assertion audit (instrument-integrity #16): 5 gates audited, gaps documented, luma stride test added |
| 2026-07-29 | — | Added completeness limitation to header; inventory is hand-enumerated, not proven complete |
| 2026-07-29 | — | PLXF instrument limitation documented: `debug_state.state_ddr` always reads S_IDLE (self-referential) |
| 2026-07-29 | — | Revised stall analysis: seq freeze (4→stable) SUPPORTS arbiter hypothesis, not contradicts it |
| 2026-07-29 | — | **ARBITER HYPOTHESIS REFUTED** by device measurement (machine actively cycling at 62 Hz) |
| 2026-07-29 | — | **ROOT CAUSE FOUND:** `pending_ready_ddr` CDC pulse width bug — 1 DDR cycle at 90 MHz, invisible to 20 MHz CLK domain |
| 2026-07-29 | — | Fix: `(sched_valid && sched_for_pending) ?` instead of `sched_valid ?` in pending_ready_ddr expression |
| 2026-07-29 | — | Added `runMultiSwapRetirement` test: exercises 3 consecutive swap retirements with active display |

---

## PLXF Instrument Limitation (discovered 2026-07-29)

### The `state_ddr` field in PLXF is a self-referential instrument

The PLXF mailbox can ONLY be written from `S_IDLE` (line 876 of `ddr_frame_store.sv`).
The `debug_state` field is `{LINE_COUNT[2:0], |y_valid, state_ddr[3:0]}`, captured
combinationally at the moment of write. **Therefore `state_ddr` in PLXF is always 0
(S_IDLE) by construction.**

If the state machine gets stuck in `S_LINE_WAIT`, `S_POLL_WAIT`, or any other state,
it will NEVER write the mailbox again. The last written `debug_state` will show S_IDLE
(the state it was in at the last successful write), not the stuck state.

**What PLXF CAN tell us:**
- `seq` incrementing → machine is alive, returning to S_IDLE regularly
- `seq` frozen → machine is stuck in a non-IDLE state (cannot write mailbox)
- `|y_valid` at last write → whether any line cache slots were valid when last in IDLE
- `underrun_count` → display starved (requested line with no valid cache entry)

**What PLXF CANNOT tell us:**
- What state the machine is in RIGHT NOW (always reports S_IDLE)
- Whether the machine is in S_LINE_WAIT vs S_POLL_WAIT after it stalls

### Reinterpretation of silicon `PLXF = 0x00000004`

Silicon shows `frame_mbox_seq=4`, `debug_state=0x00`, stable for 6 seconds:
- seq=4 and frozen → machine left S_IDLE after 4 writes and NEVER came back
- |y_valid=0 at last write → no lines were valid before it got stuck
- state_ddr=0 → **uninformative** (always 0 when captured from IDLE)

**This is CONSISTENT with the arbiter hypothesis:** machine wrote mailbox 4 times
from S_IDLE (initial + 3 heartbeat/doorbell-triggered writes over ~8.7ms), then
initiated a line fill, entered S_LINE_WAIT, and the DDR response was lost across
the unsynchronized arbiter domain crossing. Machine stuck in S_LINE_WAIT forever.

**My earlier statement that `debug_state=S_IDLE` contradicts the arbiter hypothesis
was WRONG.** The instrument cannot distinguish S_IDLE from S_LINE_WAIT after the
stall begins, because both produce the same observation: `state_ddr=0` in the last
written mailbox and no further writes.

### Why PLXS seq=1 / PLXM seq=1 but PLXF seq=4

PLXF gets extra write triggers from doorbell events (`db_bad_format`, `db_token_new`
set `frame_mbox_req`). PLXS/PLXM are triggered only by state changes and heartbeat.
In the startup window before stall, the doorbell polling generates PLXF writes but no
PLXS/PLXM triggers occur (no status_osd change, heartbeat hasn't fired yet).

---

## Frozen-Screen Capture List for w-osd (pre-run predictions)

### What to capture

Before AND after the first ARM doorbell ring, read all mailboxes:
```
PLXF  0x3007f118   (frame store state)
PLXK  0x300ff000   (doorbell / bank selection)
PLXS  0x3007f100   (frame store status)
```

Key fields in PLXF upper word `[63:32]`:
```
[63:48] underrun_count  (16 bits)
[47:40] debug_state     (8 bits) = {LINE_COUNT[2:0], |y_valid, state_ddr[3:0]}
[39:32] frame_mbox_seq  (8 bits, increments on each write)
```

### Discriminating predictions

**If arbiter hypothesis is correct** (fixed in `60df5a2`, present in next fit):
- Before doorbell: PLXF seq increments slowly (heartbeat every ~2.9ms)
- After first doorbell: PLXF seq FREEZES within ~10ms
- |y_valid remains 0 (bit 12 of upper word stays 0)
- has_frame remains 0 (from status register)
- PLXK seq advances (doorbells consumed) but PLXF seq stops

**If swap-toggle CDC hypothesis (alternative)**:
- After first doorbell: PLXF seq KEEPS incrementing (machine stays in S_IDLE)
- |y_valid remains 0
- has_frame remains 0
- Machine is alive but never initiates line fill

**THE DISCRIMINATOR:** Sample PLXF 3 times over ~100ms after first doorbell.
- If seq changes between samples → machine alive in IDLE → not arbiter (swap path broken)
- If seq frozen across samples → machine stuck → arbiter hypothesis supported

### Additional capture: `debug_state` under fix

On the FIXED core (next fit, includes `60df5a2` arbiter domain move):
- If fix works: |y_valid should become non-zero within a few ms of doorbell
- Eventually: has_frame=1 (after first vsync with pending_ready)
- seq keeps incrementing (machine healthy, returns to IDLE between fills)

### What `debug_state` values mean

| debug_state | Meaning |
|-------------|---------|
| `0x00` | LINE_COUNT[2:0]=0, no valid lines, state=S_IDLE (always when captured) |
| `0x10` | LINE_COUNT[2:0]=0, SOME valid lines, state=S_IDLE |
| `0x80` | LINE_COUNT=8 (bits[2:0]=0 for 8!), no valid lines, state=S_IDLE |
| `0xF0` | DEBUG_FORMAT_ERROR override (doorbell format bad) |

Note: LINE_COUNT=8 → `LINE_COUNT[2:0] = 3'b000` (8 mod 8 = 0), so values `0x00`
and `0x80` are indistinguishable unless LINE_COUNT is known.
Product default `LINE_COUNT=8` → bits[7:5] = `3'b000`.

### Prediction registered in advance (2026-07-29, before w-osd run)

On core `eeff4eee` (pre-fix, OLD arbiter in wrong domain):
> After ARM rings doorbell, PLXF seq will freeze. The last captured |y_valid will be 0.
> This is because the line fill enters S_LINE_WAIT and the DDR response is lost across
> the unsynchronized arbiter boundary. The machine never returns to S_IDLE.

On next fit (includes `60df5a2`):
> After ARM rings doorbell, PLXF seq will continue incrementing AND |y_valid will
> become non-zero. Eventually has_frame=1 and video displays.

If the first prediction holds and the second prediction fails, we have a SECOND bug
downstream of the arbiter fix.

---

## RCA Status (2026-07-29, REVISED after w-osd device measurement)

### Position statement — PREVIOUS RCA SUPERSEDED

The "frozen screen" as originally characterized (state machine stuck, never returns
to IDLE) **does not exist on the v0.3.0 core.** The device is actively cycling at
62 Hz refresh. The observed symptom is **8.85 fps instead of 30 fps**, caused by the
ARM hitting a 50 ms timeout on every frame because `free_bank_mask` is never non-zero.

The 112:4 ratio was an artefact of ARM-side exponential backoff in `PRESENT=both`
mode, not evidence of anything in the fabric. That constraint is withdrawn.

### The arbiter hypothesis is REFUTED

The device measurement shows `bank_vsync_count` advancing at 62/s and content being
displayed. The state machine is actively completing fetches, not stuck in S_LINE_WAIT.
My registered prediction (PLXF seq freezes after doorbell) did not hold — the machine
is alive. **The hypothesis was registered in advance and the measurement came back
against it. This is the system working as intended.**

### Actual root cause: `pending_ready_ddr` CDC pulse width (FOUND, FIXED)

**Bug:** In `ddr_frame_store.sv` line 873, the `pending_ready_ddr` expression:
```verilog
pending_ready_ddr <= swap_pending_d2 &&
    (sched_valid ? (sched_for_pending && sched_pending_ready) : pending_ready_c);
```

When `sched_valid=1` and `sched_for_pending=0` (scheduling a CURRENT-line fill, not
a prep fill), the expression evaluates to 0 even though all prep lines ARE ready.
This causes `pending_ready_ddr` to be high for only **1 DDR cycle** before being
zeroed by the current-fill scheduling on the next cycle.

At the 90/20 MHz (4.5:1) clock ratio between clk_ddr and clk, a 1-cycle (11.1 ns)
pulse on `pending_ready_ddr` cannot be reliably captured by the CLK-domain 2-FF
synchronizer (which samples every 50 ns). The swap therefore **never retires** after
`has_frame=1` enables current-line demand (which is most of the time).

**Consequence:** `swap_pending = 1` permanently → `free_bank_mask = 0` permanently
→ ARM hits 50 ms timeout on every frame → 8.85 fps instead of 30.

**Fix:**
```verilog
pending_ready_ddr <= swap_pending_d2 &&
    ((sched_valid && sched_for_pending) ? sched_pending_ready : pending_ready_c);
```

This ensures current-line scheduling does not suppress the prep-readiness signal.
`pending_ready_ddr` now stays high for the full period between prep completion and
swap retirement (potentially thousands of DDR cycles), giving the CLK domain ample
time to capture it.

**Why the bench didn't catch it:** The testbench drives both `clk` and `clk_ddr` at
the SAME frequency (1:1 ratio). At 1:1, every DDR cycle has a corresponding CLK edge,
so the 1-cycle pulse is always captured. The bug only manifests at the real 4.5:1
ratio on silicon.

### Eliminated candidates (revised)

| # | Candidate | Evidence for elimination |
|---|-----------|------------------------|
| 1 | async_fifo comb loop | Correct fix but unrelated to bank-release path |
| 2 | Arbiter in wrong domain | **Device actively cycling at 62 Hz; not stuck** |
| 3 | `want_y` single-stage sync | Glitch injection: has_frame unaffected even at rate=1 |
| 4 | `disp_buf_d2` bank race | Bank-swap test: prep path is self-consistent |
| 5 | `host_owns_fs` latch | Under DDR_FRAME_STORE, ddr_swap=0; has_frame not gated by host_owns_fs |

### Answers to parent's four questions

1. **Who writes `free_bank_mask`?** Nobody independently. It is a derived field in
   the PLXD mailbox (line 896): `swap_pending_d2 ? 2'b00 : (disp_bank_d2 ? 2'b01 : 2'b10)`.
   It is zero iff `swap_pending_d2 = 1`.

2. **Is `swap_pending=1` the cause or consequence?** ROOT CAUSE flows:
   `pending_ready_ddr` pulsed too narrow → `pending_ready_s2` never captured →
   swap never retires → `swap_pending = 1` permanent → `free_bank_mask = 0` →
   `disp_bank = 0` permanent. **One defect, three symptoms.**

3. **ARM→FPGA ACK path?** **None exists.** The protocol is one-way: ARM rings
   doorbell → FPGA fills lines → FPGA reports free bank in PLXD → ARM reads.
   There is no ARM→FPGA acknowledgement.

4. **Fix arithmetic:** Without the 50 ms wait, per-frame time = ~33 ms (decode +
   write + poll overhead). 1000/33 ≈ 30 fps. The fix removes the FPGA-side cause
   of the wait (free_bank_mask permanently 0), which is more correct than removing
   the ARM-side wait (which would mask tearing hazards).
