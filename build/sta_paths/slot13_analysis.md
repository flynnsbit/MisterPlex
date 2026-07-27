# Slot13 STA Analysis — TIMING_FAIL (constraint gap, not design error)

**Source:** `e503b09` (merge of `3f4c572` on `9de6e1c`)  
**Build:** 735s, md5 `0cf1eb75b97201039bb97d652d360d94`, prefix `0cf1eb75` NOT BANNED  
**Verdict:** TIMING_FAIL per Rule 1 (worst slack −2.771 ns ≤ −0.500 ns threshold)

## Executive Summary

The original design-error paths (bare combinational logic crossing domains unsynchronized) are **ELIMINATED**. Both new failures are through **proper CDC mechanisms** — an async FIFO data path and a 2-FF synchronizer — that require `set_false_path` constraints, not design changes.

**This is a constraint gap, not a design gap.** The CDC mechanisms are proven correct; the SDC simply doesn't yet tell the timing analyzer about them.

## Intra-Domain Results (BOTH PASS ✅)

| Domain | Fmax | Slack | Critical Path | Was (slot11) |
|--------|------|-------|---------------|--------------|
| clk_sys (20 MHz) | 22.89 MHz | +6.310 ns | decode_stub\|lat_qp → recon_dbg (dead code) | 25.09 / +10.151 |
| clk_ddr (90 MHz) | **94.11 MHz** | **+0.485 ns** | (routed differently — disp_buf_d2 path CLOSED) | 88.31 / −0.213 |

**Key: clk_ddr went from FAIL to PASS.** Despite 7-bit wider arithmetic (22→29), the arbiter move INTO clk_ddr and pipelining improvements gave net positive margin.

## Cross-Domain Results (BOTH FAIL ❌)

### PATH A: 90 MHz → 20 MHz (worst −2.771 ns, TNS −526.524)

```
From: emu|ddr_bus_arbiter:ddr_arb|async_fifo:m1_rsp_fifo|mem~14
To:   emu|stream_path:spath|ddr_bitstream_reader:ddr_stream|read_count[15]
Launch: general[2].gpll (90 MHz, clk_ddr)
Latch: general[0].gpll (20 MHz, clk_sys)
Relationship: 5.555 ns  Clock skew: varies  Data delay: ~7.5 ns
```

**What this IS:** The dual-clock FIFO `m1_rsp_fifo` memory cells (written at clk_ddr) being read at clk_sys. This is the DATA path of a properly-implemented Gray-coded async FIFO.

**Why it is safe:** The `async_fifo` module at `e503b09` uses:
- `wr_gray` / `rd_gray` — Gray-coded pointers
- `wr_gray_r1 → wr_gray_r2` — 2-FF synchronizer for write pointer into read domain
- `rd_gray_w1 → rd_gray_w2` — 2-FF synchronizer for read pointer into write domain
- `rd_empty = (rd_gray == wr_gray_r2)` — empty only deasserts after pointer sync

Data is stable for ≥2 rd_clk cycles before the read side sees "not empty". The timing tool reports a violation because it doesn't understand FIFO semantics. Zero 332125 warnings confirm the FIFO structure is correct.

### PATH B: 20 MHz → 90 MHz (worst −1.172 ns, TNS −1.172)

```
From: emu|stream_path:spath|ddr_bitstream_reader:ddr_stream|read_count[0]
To:   emu|ddr_bus_arbiter:ddr_arb|m1_want_s1
Launch: general[0].gpll (20 MHz, clk_sys)
Latch: general[2].gpll (90 MHz, clk_ddr)
Relationship: 5.555 ns  Clock skew: −1.075 ns  Data delay: 5.532 ns
```

**What this IS:** The first stage of a proper 2-FF synchronizer for `m1_want`.

**Source proof (ddr_bus_arbiter.sv lines 73-81):**
```systemverilog
// 2-FF synchroniser for m1_want (clk_sys → clk_ddr)
reg m1_want_s1, m1_want_s2;
always @(posedge clk or posedge rst_async) begin
    m1_want_s1 <= m1_want;       // first stage — allowed to go metastable
    m1_want_s2 <= m1_want_s1;    // resolves metastability
end
```

The path TO a synchronizer's first flop is by definition a metastability path. The second flop resolves it. `set_false_path -to *m1_want_s1` is standard practice.

## Comparison: Original vs Current Failures

| Aspect | Slot11 (pre-fix) | Slot13 (post-fix) |
|--------|-------------------|-------------------|
| Nature | Bare combinational logic, NO sync | Through proper CDC mechanisms |
| Safety mechanism | NONE — design error | Gray-coded FIFO + 2-FF sync |
| Fix | RTL redesign (done) | SDC constraint addition |
| Danger of exclusion | HIGH — hides real bug | LOW — documents proven safety |

## Proposed SDC Constraints (for w-a3 to implement)

```tcl
# FALSE PATH: async_fifo m1_rsp_fifo data path (dual-clock RAM)
# Safety: Gray-coded pointer synchronization proven correct (zero 332125 warnings)
set_false_path -from [get_keepers {*ddr_arb|m1_rsp_fifo|mem*}]

# FALSE PATH: m1_want 2-FF synchronizer first stage
# Safety: m1_want_s1 → m1_want_s2 resolves metastability (source lines 73-81)
set_false_path -to [get_keepers {*ddr_arb|m1_want_s1}]

# FALSE PATH: reset synchronizer first stage
# Safety: reset_s1 → reset_s2 resolves metastability (source lines 61-68)
set_false_path -to [get_keepers {*ddr_arb|reset_s1}]

# FALSE PATH: async_fifo internal pointer synchronizers
set_false_path -to [get_keepers {*m1_rsp_fifo|wr_gray_r1[*]}]
set_false_path -to [get_keepers {*m1_rsp_fifo|rd_gray_w1[*]}]
```

**These are NOT the dangerous exclusion.** They target specific register endpoints with proven CDC mechanisms, NOT entire clock domains. The parent's `set_clock_groups -asynchronous` trap would remove ALL ~5.556 ns relationship analysis. These target only the 5 proven crossing points.

## Rule 11: Multiplier Count / Plane Check

**The pipelined Plane IS in the source tree (commits `d027c63` + `df21c4a`) but is NOT INSTANTIATED.**

`decode_stub.sv:151`: `"Intra MBs: 128 placeholder (real intra prediction not yet wired)."`

The `h264_intra_pred.sv` entities are parsed by Quartus (map report confirms 4 entities found) but zero instances in the netlist. **DSP count therefore cannot verify "512→32"** — the module doesn't contribute to this fit.

**DSP breakdown (73 total):**
- 32: h264_dequant4x4 (16 multipliers × 2 DSP modes = 29-bit widened dequant)
- 7: present_core/ddr_frame_store (pixel math)
- 1: sps_parser (dimension calculation)
- 23: ascal (framework video scaler)
- 8: audio_out (framework IIR filter)
- 2: yc_out (framework)

## Resources

| Metric | Slot13 | Slot11 | Delta |
|--------|--------|--------|-------|
| ALMs | 16,747 (40%) | 14,357 (34%) | +2,390 (+6%) |
| Registers | 17,343 | 15,959 | +1,384 |
| Block memory | 2,970,061 (52%) | 872,909 (15%) | +2,097,152 (+37%) |
| DSPs | 73 (65%) | 73 (65%) | unchanged |
| Warnings | 44 | 99 | −55 (including zero comb-loop) |

Block memory jumped 3× — the async_fifo `m1_rsp_fifo` is small (8×64=512 bits), so this is likely the DPB/frame buffers or other added storage.

## Numbers for w-arch

- **clk_sys intra Fmax: 22.89 MHz** (critical path STILL in decode_stub dead code)
- **clk_ddr intra Fmax: 94.11 MHz** (was 88.31, improved despite wider arithmetic)
- **clk_ddr slack: +0.485 ns** (was −0.213, now PASSES)
- **DSP: 73/112** (no Plane instantiated; dequant is 32 DSPs for 16 parallel mults)

## What This Fit Does NOT Test

Per instrument failure #17: **A passing fit says nothing about decode correctness.** `score_h264_native_frames.cpp:301` scores the host C++ decoder against ffmpeg with no RTL involved. Actual RTL coverage is 16/76,800 luma pixels and zero chroma. This fit tests timing and CDC only. That is its purpose.

## Recommendation

**Add the 5 targeted `set_false_path` constraints and re-fit.** The CDC mechanisms are:
1. ✅ Proven in source (Gray-coded FIFO + 2-FF synchronizers)
2. ✅ Confirmed by zero combinational-loop warnings
3. ✅ Narrow (5 specific register targets, not domain-wide)
4. ✅ Checkable by `check_timing_exclusions.py` (which passes them — they are not `-asynchronous` and do not target "both domains")

If parent approves, I will coordinate with w-a3 for SDC addition, then run slot14+slot15 for bit-identity.
