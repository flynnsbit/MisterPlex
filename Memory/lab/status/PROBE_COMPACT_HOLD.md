# Probe/compact HOLD while 10420 holds fabric (2026-08-13)

**HOLD.** Do **not** re-run `/tmp/probe_fabric_alloc` on-box while **10420**
is live. Do **not** write `compact_memory`. 10420 stays. No bounce.
No W-flag-off. Cite `MLOCK_PFN_NOT_PINNED.md`. Soft-skip ≠ PASS.
**P4-DISPLAY / P4-720P-MIX** stay **TODO**. No RGB565.

Lab **`ebfe4a12`**. true480 **`07f54d9f`**. Live bin **`9fff2e76`**.

## Why standalone probe is hostile

Standalone `/tmp/probe_fabric_alloc` `tryCompact` writes
`/proc/sys/vm/compact_memory` (W-r1-probe2: `compact_memory=writable`
**and** `allocateFabricDirectSlots(tryCompact=true)`). That is a
**system-wide** compact, not probe-private.

## Timeline (cite MLOCK_PFN_NOT_PINNED)

- **19:20Z** — daemon **10420** start (alloc-time firstPfn **`0x1200`**,
  frozen `slot.phys = 0x01200000`).
- **19:35Z** — W-r1-probe2 after that start; wrote `compact_memory=1`.
- Later maps: PFN **`0x1200` gone** (HITS=0). Arena still mlocked;
  live page is **`0x1d5b0000`**. `mlock` ≠ pin (`MLOCK_PFN_NOT_PINNED.md`).

## Forbidden while 10420 holds slots

- Do **not** re-run `/tmp/probe_fabric_alloc` on-box.
- Do **not** write `/proc/sys/vm/compact_memory`.
- Do **not** bounce / kill 10411/10420 / W-flag-off / menu / Quartus.
- 10420 stays. Compact again does **not** “fix” a frozen `slot.phys`.

**HOLD ≠ PASS.** **POKE_SEEN ≠ FABRIC_PASS.** T7 NOT_RUN.

## Evidence

`MLOCK_PFN_NOT_PINNED.md` · `/tmp/misterplex-agent-W-r1-probe2.txt`
`/tmp/misterplex-agent-W-daemon-maps.txt` · `COMPANION_DEPLOY_HOLD.md`
