# play_pair=NO after idle MATCH 0x04100000 (2026-08-13)

**Status:** **play_pair=NO.** Idle poke+pagemap **MATCH** is **one** legal 338-run.
**idle MATCH ≠ play pair.** **n338=1 < 2.** **FABRIC_PASS=NO.** **T7 BLOCKED.**
Soft-skip ≠ PASS. **CARD_OK ≠ FABRIC_PASS ≠ T7.**
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
No RGB565. Do **not** compact. Do **not** re-probe. Do **not** bounce **13881**.

Lab **`ebfe4a12`**. true480 **`07f54d9f`**. Live **13881** stays.

## Idle MATCH is already one legal 338-run

W-maps-13881 **MAPS_OK**: `n338_legal=1` first=**`0x04100000`** **play_pair=NO**.
W-plxp-re2 **POKE_LIVE** src=**`0x04100000`** fd=0.
W-match-card **CARD_OK** `POKE_PAGEMAP_MATCH_04100000.md`.

That **is** a legal 338-run. Idle / chevron can keep it (`minSlots=1`).

Scheduled-task line **"REAL src_phys / hugepage idle arena"** is **STALE**:
idle REAL already **MATCH**. Do **not** re-sample.

## Play still needs two legal runs

Play path is fail-closed at **`minSlots=2`** (both-or-none).
**n338=1** is enough for idle; it is **not** a play pair.

**play_pair=NO** is a **SECOND** remaining gap **AFTER** a future connected
RBF drives the swap gate. Even then, play still needs **two** legal 338-runs.

## Miss on this RBF is silicon, not hugepage

Live **`ebfe4a12`** slot720p24h **Warning 10030** — fstore `fabric_copy_*`
undriven (`FABRIC_HIER_UNDDRIVEN.md`). **PORT_OK** is source-only
(`PORT_OK_NOT_FIT_GO.md`). Hugepage **EINVAL** (`ARENA_ALLOC_FLAKY.md`)
is **not** the next exclusive.

## Do not

- Do **not** compact (`PROBE_COMPACT_HOLD.md`) while **13881** holds slots
- Do **not** re-run `/tmp/probe_fabric_alloc` / poke / bounce / W-flag-off
- Do **not** kill **13881** / **13872**. Do **not** treat hugepage as FIT_GO
- **P4** stay **TODO**. No RGB565. Soft-skip ≠ PASS.

## Evidence (cite only; do not re-sample)

`/tmp/misterplex-agent-W-maps-13881.txt` — n338=1 first=`0x04100000` play_pair=NO
`/tmp/misterplex-agent-W-plxp-re2.txt` — POKE_LIVE src=`0x04100000` fd=0
`POKE_PAGEMAP_MATCH_04100000.md` · `ARENA_ALLOC_FLAKY.md` · `PROBE_COMPACT_HOLD.md`
`FABRIC_HIER_UNDDRIVEN.md` · `PORT_OK_NOT_FIT_GO.md`
