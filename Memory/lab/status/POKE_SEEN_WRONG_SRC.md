# POKE_SEEN but src=0x01200000 UNMAPPED (2026-08-13)

**Status:** RCA only. **POKE_SEEN.** **FABRIC_PASS=NO.** Soft-skip ≠ PASS.
**POKE_SEEN ≠ FABRIC_PASS ≠ T7.** Glass ≠ PASS (not measured).
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
No RGB565. Do **not** bounce. Do **not** kill 10411/10420. No W-flag-off.

Lab RBF **`ebfe4a12`**. true480 **`07f54d9f`** intact. Live bin **`9fff2e76`** MATCH_WIRE.

## What landed

720p PLXP `@ 0x3047F138` is sticky published (W-plxp-ro T0–T3, ~69 s):

- word0 magic = `0x504C5850` (`"PLXP"`) **magic_ok=YES**
- word1 src   = **`0x01200000`** sticky (matches 10420 log `REAL slot=0x01200000 how=arena`)

pokePlxp **did** land. This inverts W-fabric-h (PLXP 0/0 STUB).

## Why it cannot swap

`0x01200000` is **not** a page in live **10420** pagemap (W-daemon-maps):

- Whole-AS PFN `0x1200` **HITS=0**
- 18 MiB into the 32 MiB arena VA (`b000a000-b200a000` → `va 0xb120a000`) is present
  but phys **`0x1d5b0000`**, not the poked slot
- Proven legal 338-runs **unused by poke**:
  - **`0x0562a000`** (n=470) va=`0xb1a98000`
  - **`0x05a00000`** (n=370) va=`0xb1e98000`

Log REAL ≠ live first legal. Do **not** harvest `0x01200000` as the product slot.

## Swap not complete

- **PLXD** `@ 0x3047F128`: **fd=0** pending=0 free=0x2 disp=0 frozen (reset-class)
- **PLXF** LIVE (seq moving, underrun=0) — beam clock alive; swap is not
- `fabric_allows_swap` needs `fabric_copy_visible && token match` — not proven
- **FABRIC_PASS=NO.** has_frame not visible. T7 NOT_RUN.

## Do not

- Do **not** bounce / menu / load_core / Quartus
- Do **not** kill / SIGSTOP 10411 / 10420 / 18071
- Do **not** spawn W-flag-off
- **P4** stay **TODO**. No RGB565. Soft-skip ≠ PASS.

## Evidence

- `/tmp/misterplex-agent-W-plxp-ro.txt` — POKE_SEEN src=`0x01200000` fd=0
- `/tmp/misterplex-agent-W-daemon-maps.txt` — DAEMON_REAL `0x0562a000`/`0x05a00000`; log UNMAPPED
- `/tmp/misterplex-agent-W-bin-pin.txt` — MATCH_WIRE `9fff2e76`
- Gate (do not rewrite): `EBFE4A12_FABRIC_SWAP_GATE.md`
