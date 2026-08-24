# PRODUCT_PLXF_M1_HOLD — register m1 pins; hold grant+WE until raw !BUSY accept

Canonical SoT copy lives in the worktree:

`/home/shawn/Projects/MisterPlex-wt-480p-lessons/Memory/lab/status/PRODUCT_PLXF_M1_HOLD.md`

**Worker:** D-plxf-m1-hold · **2026-08-14T21:16Z** · **CARD_OK only.**
**NAME=`PRODUCT_PLXF_M1_HOLD`** · **APPLY_LIVE=NO** · **FIT_GO=NO** (this card does **not** stamp).
**CARD_OK ≠ unique-24 ≠ FIT_GO.** **RCA_OK ≠ FIT_GO.**
**SUPERSEDES** D-plxf-m1-next **21:06Z** `UNNAMED` / HOLD (RCA was ABSENT; now **PRESENT 21:10Z**).

RCA **`R-plxf-m1-rca` 21:10Z** **RCA_OK**: bug **`M1_ACK_ON_BUSY_R` / `GRANT_DROP_ON_FIRST_WE`** CLASS=**`PLXF_WE_NEVER_COMMITTED`**.
Closed play **`f02aa88b`** pfps=**12.5** presented=**189** F@118=**EMPTY** F@110=**LEFTOVER_PLXM**. unique24=**FAIL** (2/5). **12.5 ≠ 23.9.**
Freeze: store **`aa3bce59`** writer **`16be1515`** arbiter **`50bf5754`**. Do **not** edit those RTL files.
Keep exclusive m1. Keep `DDRAM_*=fsm_*`. Keep ADDR=`PLXF_W`.
Lab **`f02aa88b` SKIP_RESTORE**. Bak **KEEP `07f54d9f`**.
Do **not** Quartus / play / `/bin/fpga` / n29 / `plxf-fsm.patch` / replay **`f02aa88b`** / **`849bc600`** / **`347bb7ea`** / invent 23.9 / name **`PRODUCT_PLXF_FSM_ISSUE`**.
