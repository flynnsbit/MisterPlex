# PORT_OK is not FIT_GO (2026-08-13)

**HOLD_OK.** Source-only PORT_OK does **not** authorize exclusive / Quartus / deploy.
**FIT_GO=consumed-h / NO.** Soft-skip ≠ PASS.
**HOLD_OK ≠ READY_YES ≠ FABRIC_PASS ≠ BUILD_OK.**
**PORT_OK ≠ FABRIC_PASS ≠ T7 ≠ pfps.**
**P4-DISPLAY / P4-720P-MIX stay TODO.** No RGB565.

## Live silicon (unchanged)

W-port-rtl **PORT_OK** is **source-only** on the lessons tree.
Live lab RBF is still **`ebfe4a12`** with slot720p24h **Warning 10030**
undriven fstore nets (`fabric_copy_visible` / `fabric_copy_token` → 0).
**fd=0.** See `FABRIC_HIER_UNDDRIVEN.md` + `FABRIC_PORT_PASSTHRU.md`.

## Exclusive

Parent **FIT_GO=consumed-h / NO** (loop **TICK=20:45Z**). Exclusive **FREE**
but this fleet **MUST NOT** start **slot720p24i** (or any Quartus) until
parent writes a **NEW FIT_GO** token naming the **port-land freeze md5s**.
This card is **not** that token.

## Deploy

**READY_TO_DEPLOY=NO.** **ZERO additional menu.**
Do **not** deploy **`17dd3b56`** / **`0bcc6081`**. Keep true480 **`07f54d9f`**.
Do **not** bounce / kill **13881**. Do **not** W-flag-off. Do **not** compact.

## When parent eventually FIT_GO (NOT this card)

H1 veto still: no `u_content_window`; no clk_pix sample of `fabric_copy_*`;
PLXP **`0x3047F138`**; no `copy_done_level`; NEW_RBF ∉ banned
`{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0,…}`; **ONE** menu after
**BUILD_OK+LOCK_OK** only.

## Evidence

`/tmp/misterplex-agent-W-port-rtl.txt`
`Memory/lab/status/FABRIC_PORT_PASSTHRU.md`
`Memory/lab/status/FABRIC_HIER_UNDDRIVEN.md`
`/tmp/misterplex-loop-status.txt` TICK=20:45Z
