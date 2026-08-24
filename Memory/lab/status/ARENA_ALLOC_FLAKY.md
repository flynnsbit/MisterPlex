# Arena alloc flaky — standalone PROBE_REAL ≠ official pair (2026-08-13)

**Status:** RCA only. **PROBE_REAL flaky.** Soft-skip ≠ PASS. **STUB reconfirm ≠ allocator broken forever.**
**P3-720P24** stays **IN_PROGRESS / pfps FAIL**. **P4-DISPLAY / P4-720P-MIX** stay **TODO**.
No RGB565. **PROBE_REAL ≠ T7.** **UNIT_OK ≠ pfps.** Do **not** bounce misterplexd. No Quartus / menu.

Lab RBF **`ebfe4a12`**. true480 **`07f54d9f`** intact. Lessons `cached_src_phys.hpp`
`tryArenaFill` / `allocateFabricDirectSlots` (`minSlots`).

## Ranking (both standalone `/tmp/probe_fabric_alloc` runs)

| Path | 19:06Z W-r1-probe | 19:16Z W-r1-re |
|------|-------------------|----------------|
| hugepage | MAP_FAILED **EINVAL** | same |
| 2 MiB memalign longest | **32** pages | **212** pages |
| n338 memalign | 0 | 0 |
| arena32 diag n338_legal | **1** | **3** |
| official allocate | **REAL** how=arena `0x03c00000`/`0x03800000` | **STUB** slots 0 |

Need 338 pages (1,382,400 B). Hugepage is **dead** (no HUGETLBFS / HugePages_*).
Memalign virt+mlock ok; longest 32 then 212 still **<338**. 32 MiB arena **can**
yield legal 338-runs (seen 1 then 3). 16 MiB arena: 0 legal both times.

## Why diag 3 ≠ official pair

`printArenaDiag` mmap+scan+**munmap**. Official `allocateFabricDirectSlots`
then remmaps: hugepage fail → compact → memalign retries fail → `tryArenaFill`
**fresh** mmap. Default **minSlots=2**: `got < need` → munmap → fail-closed STUB.
First run: diag 1, official still found a pair. Second: diag **3**, official **0**.
Churn is not deterministic. Pair-legal is **not repeatable**. One-shot REAL ≠ confirmed.

STUB reconfirm is **not** “allocator broken forever.” 32 MiB arena already
produced legal runs; the pair-legal gate on a *new* mapping is flaky.

## Play vs idle (chevron)

- **Play** needs **2** legal slots (`kFabricDirectNeedSlots=2`, both-or-none).
- **Idle / chevron** needs **1** (`minSlots=1`) so a single 338-run is **kept**
  instead of munmap’d. That is the right product path for idle paint.

Live daemon still **STUB**: W-idle-maps `max_contig=1` LEGAL_338=0. Heap 152 KiB.
Do **not** bounce / W-flag-off. Probe process REAL ≠ daemon paintIdle REAL ≠ T7.

W-unit-arena **UNIT_OK** on freeze `c804acf9`. Live tree INV_PY=1 after sibling
`minSlots=1` dropped `idleFabric_.real()` — harvest UNIT_OK only onto freeze.

## Not claimed

FABRIC_PASS / glass / pfps ≥23.9 / T7 / daemon REAL / P4 / RGB565.
Soft-skip ≠ PASS.

## Evidence

- `/tmp/misterplex-agent-W-r1-probe.txt` (19:06Z REAL arena pair)
- `/tmp/misterplex-agent-W-r1-re.txt` (19:16Z STUB Repeatable=NO)
- `/tmp/misterplex-agent-W-idle-maps.txt` (daemon max_contig=1)
- `/tmp/misterplex-agent-W-unit-arena.txt` (UNIT_OK freeze; live INV_PY=1 minSlots=1)
- lessons `host/libmisterplex/cached_src_phys.hpp` `tryArenaFill` / `minSlots`
