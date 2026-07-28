# BUILD_OK Report — Slot16/17

## Provenance
```
Resident RBF md5: d01f19a7ba4d4cd2784237c6e81999fe
Deploy time (UTC): 2026-07-28T02:09:52Z
Source commit: 95c3687 (feat/cap-sdc-cdc)
  Parent: aed1e8f (6 SDC constraints on e503b09)
  Cherry-pick: 664399e fix(ddr_frame_store): pending_ready_ddr CDC pulse too narrow
```

**Fix `664399e` is explicitly IN this build.** The change:
```systemverilog
// BEFORE (broken at 4.5:1 ratio):
pending_ready_ddr <= swap_pending_d2 &&
    (sched_valid ? (sched_for_pending && sched_pending_ready) : pending_ready_c);
// AFTER (664399e — pulse stays high until swap retires):
pending_ready_ddr <= swap_pending_d2 &&
    ((sched_valid && sched_for_pending) ? sched_pending_ready : pending_ready_c);
```

## Two-Slot Bit-Identity
```
slot16: d01f19a7ba4d4cd2784237c6e81999fe  BUILD_OK  724s
slot17: d01f19a7ba4d4cd2784237c6e81999fe  IDENTICAL ✅
```

md5 prefix `d01f19a7` ∉ banned set. **CLEAR.**

## Timing — All Positive, Zero TNS

| Domain | Setup Slack | Hold Slack | Fmax | Required |
|--------|------------|-----------|------|----------|
| clk_sys (general[0], 20 MHz) | +1.351 ns | +0.244 ns | 23.68 MHz | 20 MHz ✅ |
| clk_ddr (general[2], 90 MHz) | **+0.334 ns** | +0.323 ns | **95.06 MHz** | 90 MHz ✅ |
| pll_hdmi | +0.338 ns | +0.262 ns | 156.4 MHz | — |
| pll_audio | +16.256 ns | +0.252 ns | 40.94 MHz | — |
| h2f_user0_clk | +3.265 ns | +0.379 ns | 148.48 MHz | — |

**Negative rows: 0. TNS: 0.000 for all domains.**

Compared to previous fit (`9f364cb1`):
- clk_ddr Fmax: 93.28 → **95.06 MHz** (+1.78 MHz improvement)
- clk_ddr setup: +0.225 → **+0.334 ns** (more margin)
- clk_sys setup: +0.978 → **+1.351 ns** (more margin)

**The RTL change at `664399e` IMPROVED timing** — consistent with reducing a combinational
path through the `sched_valid ?` mux (one fewer AND input in the critical leg).

## Metastability / CDC
- 420 synchronizer chains found (same as previous fit)
- Worst-case MTBF: 1e+09 years
- Shortest chain: 2 registers
- Worst-case settling time: 3.791 ns

## Deploy Status
```
Method: ONE menu bounce (Menu → Plex)
CORENAME: Plex ✅
MiSTer process: /media/fat/MiSTer /media/fat/_Utility/Plex.rbf
misterplexd: running (PID 17760)
```

## Mailbox Stability (3 reads, 2s apart)
```
PLXS: 0x504C5853 / 0x0C530010  (magic ✅, config stable)
PLXM: 0x504C584D / 0x00000053  (magic ✅, stable)
PLXF: 0x504C5846 / 0xFFFF10xx  (magic ✅, underrun=0xFFFF, seq ADVANCING)
  Read1: 0xFFFF10CD  Read2: 0xFFFF102E  Read3: 0xFFFF1075
PLXK: 0x504C584B / 0x20004F7C  (magic ✅, stable — no stream)
```

## Bank-Release Fix Validation — CANNOT TEST YET
```
STREAM=0 in misterplex.conf — no content flowing.
underrun_count=0xFFFF (no frames delivered).
free_bank_mask, swap_pending, pfps — UNTESTABLE without active stream.
```

**The discriminating measurement requires someone to set STREAM=1 and start playback.**
When that happens, the expected readings are:
```
free_bank_mask:  0→non-zero and changing  (was 0 forever on 9f364cb1)
swap_pending:    1→toggling               (was 1 forever)
pfps:            8.85→approaching 30      (was capped by 50ms timeout)
[STALL] log:     present every frame→absent
```

If `free_bank_mask` moves and `pfps` does NOT approach 30, the 50ms timeout was
not the only bottleneck, and the 48% present rate becomes the live question.

## SDC Constraints (unchanged from previous fit)
All 6 constraints from `aed1e8f` are in this build (same SDC, same branch):
1. `set_false_path -to *ddr_arb|m1_want_s1`
2. `set_false_path -to *ddr_arb|reset_s1`
3. `set_false_path -to *m1_rsp_fifo|wr_gray_r1[*]`
4. `set_false_path -to *m1_rsp_fifo|rd_gray_w1[*]`
5. `set_max_delay -from *m1_rsp_fifo|mem* 50.0` ← bounded, NOT false-pathed
6. `set_false_path underrun_count→frame_mbox_last`
