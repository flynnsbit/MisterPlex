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
| 14 | `status_osd` | clk→clk_ddr | 16 | multi-bit | Toggle-snapshot (`status_osd_toggle` 2-FF sync, data captured on edge) | SAFE (fixed: was 2-FF binary sync, fed PLXS mailbox) |
| 15 | `sdram_status` | clk→clk_ddr | 24 | multi-bit | Toggle-snapshot (`sdram_status_toggle` 2-FF sync, data captured on edge) | SAFE (fixed: was 2-FF binary sync, fed PLXM mailbox) |
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

## Related-edge sensitivity (clk_sys overclock / 720p plan)

Both domains stay in one `set_clock_groups -exclusive` PLL group (`sys_top.sdc`), so
STA times crossings with the **minimum positive related rising-edge Δ**, not as fully
async. Shipping **20/90 → 5.556 ns** matches STA path panels on `8fdf440f`
(`c_line[*] → c_line_v1[*]`, data delay **3.5–3.8 ns**, slack **+0.793**).

| clk_sys | clk_ddr | Min related Δ | vs data-delay class ~3.5–3.8 ns | Gate / fit |
|--------:|--------:|--------------:|----------------------------------|------------|
| 20 MHz (ship) | 90 | **5.556 ns** | Headroom (~1.7 ns class) | Measured PASS |
| 25 MHz (A) | 90 | **2.222 ns** | **Tighter than data delay → expect setup HARD_FAIL** | PROPOSED; STA required |
| 27 MHz (C) | 90 | **3.704 ns** | Marginal / likely fail after uncertainty | PROPOSED; not preferred |
| 30 MHz (B) | 90 | **11.111 ns** (3:1) | Setup comfortable; **same-edge hold family** | **Preferred** first bump |

### Crossings re-audited for a ratio change (no new false_path)

| # | Signal / path | Dir | Current protection | At 25/90 (2.22 ns) | At 30/90 (11.11 ns) |
|---|---------------|-----|--------------------|--------------------|---------------------|
| 1–4,10–12 | reset, swap/start toggles, bank levels | sys→ddr | 2-FF / toggle | Pulse width shrinks with sys period; toggles still OK if held ≥1 sys clk | OK if held ≥1 sys clk |
| 5–9 | disp_bank/buf, has_frame, swap_pending, pending_bank | ddr→sys | 2-FF level | Level sync OK; latency in sys cycles unchanged count | Same |
| 13 | `want_y` Gray | sys→ddr | Gray 2-FF | Gray still sound; faster sys updates Gray more often | OK |
| 14–15 | status_osd / sdram_status snapshot | sys→ddr | Toggle-snapshot | Data must remain stable across tighter edge — protocol already holds through toggle | OK |
| 16,28 | `input_fifo` | sys→ddr | async_fifo Gray AW=2 | Pointer CDC OK; **throughput** scales with sys; depth may need +1 if burstier | Check fill under 720p |
| 17 | line_buf_ram dual-port | ddr wr / sys rd | M10K dual clock | Not edge-related STA path; address stability still required | Same |
| 18–21 | arbiter want/busy/cmd | sys↔ddr | 2-FF + protocol hold | **m1_busy** 2-FF OK; cmd multi-bit must stay stable while busy low — shorter sys period reduces hold window in ns | OK with same protocol |
| 22–23,30 | `m1_rsp_fifo` dout | ddr→sys | async_fifo Gray AW=3 | Pointer CDC OK; FWFT registered; **do not** expand false_path | OK |
| meta | `y_line`/`c_line`/`y_bank` → `*_v1/*_v2` | ddr→sys | Direct related-clock sample (STA-timed) | **Binding class** — 3.8 ns data into 2.22 ns edge → **FAIL unless shortened** | 11.11 ns edge → setup OK if data stays ~4 ns; **hold STA mandatory** |

**Mitigations allowed:** deepen async_fifo only with beat-conservation proof; keep Gray/toggle protocols; retime meta holds on ddr before crossing; **never** `set_false_path` the meta bus or whole general[0]↔general[2].

Contract + gate: `assets/pll_clock_contract.json`, `scripts/check_pll_clock_contract.py`.
Full proposal: `.agent-work/w-clock/P720_CLOCK_OVERCLOCK_PROPOSAL.md`.

---

## Changelog

| Date | Commit | Change |
|------|--------|--------|
| 2026-07-27 | `d86c183` | audio_fifo: binary→Gray-coded pointer CDC |
| 2026-07-27 | `60df5a2` | ddr_bus_arbiter: moved from clk_sys to clk_ddr |
| 2026-07-27 | `3c6d1d2` | ddr_bus_arbiter: added m1 response FIFO (beat-drop fix) |
| 2026-07-27 | `610c298` | ddr_bus_arbiter: registered + 2-FF sync on m1_busy |
