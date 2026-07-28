# SLOT14+15 FINAL REPORT — BUILD_OK + DEPLOY_OK

**Source:** `aed1e8f` (feat/cap-sdc-cdc: e503b09 + 6 targeted CDC SDC constraints)  
**RBF md5:** `9f364cb1c09a51fc50d0792978889cbf` (BOTH slots, BIT-IDENTICAL)  
**Deployed:** 2026-07-27T19:29 via ONE `load_core` command

## TIMING: CLOSED ✅

| Domain | Setup | Hold | Recovery | Removal |
|--------|-------|------|----------|---------|
| clk_sys (20 MHz) | +0.978 | +0.244 | +47.596 | +1.702 |
| clk_ddr (90 MHz) | +0.225 | +0.349 | +0.633 | +2.198 |
| All others | ≥ +0.508 | ≥ +0.257 | ≥ +4.491 | ≥ +1.114 |

**All slack ≥ 0.000 ns on every check. Zero negative paths.**

## FMAX (for w-arch)

| Clock | Fmax | Required | Margin | vs Slot11 |
|-------|------|----------|--------|-----------|
| clk_sys | 23.39 MHz | 20 MHz | +3.39 | was 25.09 (decode_stub dominated) |
| clk_ddr | **93.28 MHz** | 90 MHz | **+3.28** | was 88.31 → **improved** |

clk_sys critical path: STILL `decode_stub` (dead code / simulation shim).
clk_ddr critical path: CLOSED (was −0.213 ns on `disp_buf_d2→DDRAM_ADDR`).

## DETERMINISM

```
slot14: 9f364cb1c09a51fc50d0792978889cbf  (717s, 1770MB peak)
slot15: 9f364cb1c09a51fc50d0792978889cbf  (692s, 1764MB peak)
BIT-IDENTICAL ✅
```

Build determinism proven for the second time in project history.
NUM_PARALLEL_PROCESSORS = 2 (preserved from QSF, not overridden).

## DEVICE STATE POST-DEPLOY

Mailbox 3-read stability check (1s spacing):

| Register | Magic | Data | Stability |
|----------|-------|------|-----------|
| PLXS | PLXS ✅ | 0x07150010 | STABLE (all 3 reads) |
| PLXM | PLXM ✅ | 0x00000015 | STABLE (all 3 reads) |
| PLXF | PLXF ✅ | seq incrementing | LIVE (no stall) |
| PLXK | PLXK ✅ | seq incrementing | LIVE (no stall) |

**Key observation:** The old core (`eeff4eee`) had PLXF stuck at seq=4. This core has
PLXF and PLXK sequence counters actively incrementing. The mailbox machinery is LIVE —
the published-then-stalled state has changed.

underrun_count = 0xFFFF (saturated): frame store requesting data, none loaded.
This is expected behavior for a core with no stream attached.

## FBAR

OBSOLETE for v3+ cores. Script header states: "The v3 CONF_STR removed the debug
menu items this script drives." No v3 FBAR test exists.

## HARD RESIDUAL

Not executable without an active decode stream. The core is idle (no stream loaded).
The residual path processes ONE 4×4 block (decode_stub.sv:151, pred=128 placeholder).
Without bitstream data, residual checksum = XOR of sixteen 0x80 values = 0x00.

## ATTRIBUTION

Four CDC defects fixed as a set; stall resolved; individual RCA not established:
1. Arbiter domain move (clk_sys → clk_ddr)
2. Response FIFO (async_fifo for m1 responses)
3. m1_busy 2-FF synchronizer
4. want_y Gray-code eviction

## WHAT THIS PROVES AND DOES NOT PROVE

**PROVES:**
- Timing closed on all paths (setup, hold, recovery, removal, min pulse width)
- CDC mechanisms functioning (mailbox stable, no garbled reads, seq incrementing)
- Build determinism (identical md5 across two independent compilations)
- Zero combinational-loop warnings (async_fifo structure correct)
- The disp_buf_d2→DDRAM_ADDR timing violation is resolved
- clk_ddr improved from 88.31 to 93.28 MHz despite wider arithmetic

**DOES NOT PROVE:**
- Decode correctness (instrument failure #17: RTL coverage is 16/76,800 luma pixels, 0 chroma)
- Intra prediction works (instrument failure #19: NOT INSTANTIATED, pred=128 placeholder)
- Stall root cause (4 fixes landed as a set; RCA not established)
- Performance under load (no stream tested)

BUILD_OK + DEPLOY_OK ≠ hard PASS. This fit tests timing and CDC. That is its purpose.
