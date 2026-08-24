# mlock+compact did not keep alloc-time PFN 0x1200 (2026-08-13)

**Status:** RCA only. **CARD_OK ≠ PASS.** **POKE_SEEN ≠ FABRIC_PASS.** Soft-skip ≠ PASS.
**T7 NOT_RUN.** P3-720P24 stays **IN_PROGRESS / pfps FAIL**.
**P4-DISPLAY / P4-720P-MIX** stay **TODO**. No RGB565. Do **not** bounce.

Lab **`ebfe4a12`**. true480 **`07f54d9f`**. Live bin **`9fff2e76`**. kernel **5.15.1-MiSTer**.
Daemon **10420** start **19:20Z**. Probe2 `compact_memory=1` **19:35Z**. Maps **19:43Z**.

## Frozen slot.phys

`paintIdle` allocates **once** (`idleFabric_.slot[0].phys == 0`), then
`idleSrcPhys = slot[0].phys` forever. No re-walk. No re-resolve.
`tryArenaFill` stores `phys = firstPfn<<12` and `mlock`s the 32 MiB arena.

**`0x01200000` = alloc-time firstPfn `0x1200` << 12.** 10420 log repeats
`REAL slot=0x01200000 how=arena`. Later whole-AS pagemap: PFN **0x1200 HITS=0**.
arena+`0x01200000` is now phys **`0x1d5b0000`**. Live legal unused:
**`0x0562a000`** / **`0x05a00000`**.

Arena still **Rss=Locked=32768k** (`VmFlags lo`). Lock ≠ same PFN.

## mlock ≠ pin; compact is hostile

`mlock` on **5.15.1** keeps pages in RAM. It does **not** block compaction
migrate. Alloc-time PFN is not a pin. mlock+compact **did not keep** `0x1200`.

W-r1-probe2 **19:35Z** (15 min after 10420 start) wrote
`/proc/sys/vm/compact_memory=1` — writability print **and**
`allocateFabricDirectSlots(tryCompact=true)`. Standalone compact against a
**live daemon arena** is hostile: it can move 10420's mlocked pages while
`slot.phys` stays frozen at `0x01200000`.

**Do not** write `compact_memory` on-box while **10420** holds fabric slots.

## Host fix (this card does not bounce)

Re-resolve live PFN from `slot.virt` before poke (or reject missing PFN).
Do **not** bounce / kill 10411/10420 / W-flag-off / menu / Quartus.
Do **not** compact again to “fix” it.

Migrate-after-freeze fits this timeline. Identity store is not distinguished
without an alloc-time dump — not a field-swap. **Not PASS.**

## Do not

- Do **not** invent FABRIC_PASS / T7 / pfps / glass
- **POKE_SEEN ≠ FABRIC_PASS.** Soft-skip ≠ PASS
- **P4** stay **TODO**. No RGB565

## Evidence

- `/tmp/misterplex-agent-W-slot-rca.txt` — freeze `firstPfn<<12`
- `/tmp/misterplex-agent-W-daemon-maps.txt` — PFN 0x1200 HITS=0; legal pair
- `/tmp/misterplex-agent-W-r1-probe2.txt` — 19:35Z `compact_memory=writable`
- `POKE_SRC_01200000.md` · `POKE_SEEN_WRONG_SRC.md`
