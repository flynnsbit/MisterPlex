# poke+pagemap MATCH 0x04100000 on 13881 (2026-08-13)

**Status:** **MATCH.** **POKE_LIVE.** **FABRIC_PASS=NO.** Soft-skip ≠ PASS.
**POKE_LIVE ≠ FABRIC_PASS.** **MATCH ≠ T7.** Glass / pfps ≠ PASS (not measured).
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
No RGB565. Do **not** bounce. **13881 stays.** No W-flag-off. No compact.

Lab **`ebfe4a12`**. true480 **`07f54d9f`** intact. Live exe **`54ff33a0`**.
TWIN_OK: 13881 owns :3005 FABRIC=1 (W-twin-re2). 10420/10411 DEAD.

## What MATCHES

Live 720p PLXP `@ 0x3047F138` (W-plxp-re2 T0–T3 ~66 s):

- word0 magic = `0x504C5850` (`"PLXP"`) **magic_ok=YES**
- word1 src   = **`0x04100000`** sticky (≠ `0x01200000` ≠ `0x0562a000` ≠ `0x05a00000`)

Live 13881 pagemap (W-maps-13881): **one** legal 338-run:

- phys **`0x04100000`** va=`0xb1593000` run=512 pfn0=`0x4100` **HITS=1**
- `n338_legal=1`  **play pair still NO** (need 2)
- log `src_phys=REAL slot=0x04100000 how=arena` **MATCH** that 338-run

src MATCH legal 338-run. This **inverts** `POKE_SEEN_WRONG_SRC.md`
(10420 stale **`0x01200000`**). Whole-AS PFN `0x1200` **HITS=0** on 13881.
arena+`0x01200000` is present but phys **`0x04ef7000`**, not a slot.
Do **not** harvest `0x01200000` as the product poke.

## Swap still not complete

- **PLXD** `@ 0x3047F128`: **fd=0** pending=0 free=0x2 disp=0 frozen (reset-class)
- **PLXF** LIVE (seq moving, underrun=0) — beam clock alive; swap is not
- Play pair still **NO**. Idle inventory (1 slot) ≠ T7
- **FABRIC_PASS=NO.** has_frame not visible. T7 NOT_RUN.

## Do not

- Do **not** bounce / menu / load_core / Quartus / compact
- Do **not** kill / SIGSTOP **13881** / 13872 / 18071 — **13881 stays**
- Do **not** spawn W-flag-off
- **P4** stay **TODO**. No RGB565. Soft-skip ≠ PASS.
- **MATCH ≠ T7.** **POKE_LIVE ≠ FABRIC_PASS.**

## Evidence

- `/tmp/misterplex-agent-W-plxp-re2.txt` — POKE_LIVE src=`0x04100000` fd=0
- `/tmp/misterplex-agent-W-maps-13881.txt` — MATCH `0x04100000` n338=1 play_pair=NO
- `/tmp/misterplex-agent-W-twin-re2.txt` — TWIN_OK 13881 :3005 left alive
- stale invert: `POKE_SEEN_WRONG_SRC.md` (`0x01200000` UNMAPPED)
