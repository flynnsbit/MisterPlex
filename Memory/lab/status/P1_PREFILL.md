# P1_PREFILL — CLOSED as unique24 path (host warmup_prefill)

**Worker:** T-prefill-closed · **2026-08-15T22:18Z**
**PLAY=NO Quartus=ZERO RTL=NO APPLY=NO.** Did **not** play. Did **not** FIT.
Did **not** restamp FIT_GO / PLAY_GO / BUILD_OK.
**CLOSED=YES.** **BAN_bitstream=NO.**
**leftover=`2bbe6755` living OK.** **FIT_GO=NO.** **unique24=FAIL.**
**INVENT_23.9=NO.** Soft-skip ≠ PASS.
**Do not reopen prefill as a unique24 path.**

## Status

| | |
|--|--|
| **NAME** | **`P1_PREFILL`** (HOST `warmup_prefill` n=2 t0_rearm) |
| **Status** | **CLOSED as unique24 path.** SAME_CLASS leftover. |
| **RBF** | **`2bbe6755`** (`2bbe6755d0bc9ee8b2dd6089b6536fb2`) living leftover |
| **Prefill score** | pfps=**27.8** hw_fps=**19.93** presented=**416** drops=**0** F@118=**YES** |
| **first_1s** | still **~10** (PLAY_GO **10.3/9.4**) — did **not** remove 3 s ramp |
| **vs fair 2bbe** | **27.9 / 19.86** presented=**419** — **SAME_CLASS** Δhw=**+0.07** |
| **vs ac95 U1** | **28.0 / 19.51** presented=**420** — **SAME_CLASS** Δhw=**+0.42** |
| **unique24** | **FAIL 4/5** (hw only). **19.93 ≠ 23.9.** |
| **FIT_GO** | **NO** — do **not** restamp. Do **not** reopen prefill. |
| **BAN bitstream** | **NO.** CLOSED-path ≠ BAN-the-bitstream. |
| **Next exclusive** | **NEW** name. Not PREFILL cousin. Not RDYWIN. Not `112bb`. Not U1. |

Cite `/tmp/pfps-720p24-2bbe-prefill.txt` · `/tmp/pfps-720p24-2bbe6755-l4.txt` ·
`/tmp/pfps-720p24-ac95-u1-inproc.txt` · `/tmp/misterplex-PLAY_GO_FREDDO.parent`
22:07Z `PREFILL=CLOSED` `first_1s=10.3/9.4` · `/tmp/misterplex-loop-status.txt`
TICK=`P1_PREFILL_CLOSED` · `/tmp/misterplex-CLOSED-P1_PREFILL.txt` ·
`/tmp/misterplex-agent-T-prefill-closed.txt` ·
`arm/misterplexd/media_player.cpp` L3752–3783.

## unique24 five gates (prefill play only)

| gate | need | `2bbe` prefill | hit |
|------|------|----------------|-----|
| pfps | ≥23.9 | **27.8** | PASS |
| hw_fps | ≥23.9 | **19.93** | **FAIL** |
| drops | 0 | 0 | PASS |
| presented | >0 | 416 | PASS |
| MAGIC_F@+0x118 | YES | YES | PASS |

→ unique24=**FAIL**. **27.8 ≠ unique24 pair.** Soft-skip ≠ PASS.

## Cite 27.8/19.93 vs 27.9/19.86 vs 28.0/19.51

| | pfps | hw_fps | presented | ARM | note |
|--|-----:|-------:|----------:|-----|------|
| ac95 U1 | **28.0** | **19.51** | 420 | `b06a433c` | produce PASS |
| `2bbe` fair L4 | **27.9** | **19.86** | 419 | `97643cb8` | RDYWIN closer CLOSED |
| `2bbe` PREFILL | **27.8** | **19.93** | 416 | `fc2bcd53` | n=2 t0_rearm; first_1s ~10 |

Freddo beam 1312×762 @ 24 MHz ≈ **24.006 Hz**. Unused beams on prefill:
**24.006 − 19.93 ≈ 4.08 /s**. Gate hole **23.9 − 19.93 = 3.97 Hz**.
Host prefill did **not** close unique24. Same class as leftover 2bbe / ac95.

## first_1s still ~10

Parent PLAY_GO **22:07Z**: `first_1s=10.3/9.4`. Parent 22:08Z:
`PREFILL=27.8/19.93 n=2 t0_rearm first_1s still ~10`.
`warmup_prefill` primes two ring slots then re-arms t0 / hw baseline.
Prime + re-arm still opens at **~10 Hz**. Did **not** remove the 3 s ramp.

## Not P3_960_SETTLE_PREFILL

This card is HOST **P1_PREFILL** on living **720p** leftover `2bbe`.
`P3_960_SETTLE_PREFILL` is the 960-era DESIGN_HOLD (L88/L90). Do **not**
APPLY that card from this score. L90 already: SETTLE cannot close if
walk remains. Do **not** restamp `P3_960_SETTLE_PREFILL.md`.

## KEEP

Doorbell **+0x118**. PHYS **0x30180000**. CATCH **1312/720/762**.
NUM_BANKS=**3**. HDMI **74250**. Leftover **`2bbe6755`**.
ac95 sidecar **KEEP**. bak **`07f54d9f` UNTOUCHED**.
Do **not** reopen host PREFILL. Do **not** replay RDYWIN exclusive.

## Next

P1 (FPGA swap so hw_fps≥23.9) stays **BLOCKED** (`DESIGN=none`).
This **name** is **CLOSED**. Next exclusive must be a **NEW** name
(parent/user grant). **FIT_GO=NO** this worker.
**PLAN_OK ≠ FIT_GO ≠ unique-24.**
