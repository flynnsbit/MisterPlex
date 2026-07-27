# MiSTerPlex CDC Crossing Inventory

**Owner:** w-a3 (DDR frame store, async FIFOs, clock-domain crossing, deblocking)
**Date:** 2026-07-27
**Branch:** `feat/a3-frame-store` @ `610c298`
**Scope:** All crossings between `general[0].gpll` (clk_sys, 20 MHz) and
`general[2].gpll` (clk_ddr, 90 MHz) in the DDR presentation and streaming paths.

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
