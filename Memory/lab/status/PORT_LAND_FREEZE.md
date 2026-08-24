# Port-land freeze (2026-08-13)

**W-freeze-h.** **SLOT=slot720p24i** (future; **NOT launched**). **FIT_GO=NO.**
Freeze snapshot only. Parent has **not** authorized slot720p24i.
**READY_TO_DEPLOY=NO.** **BUILD_OK=NO.** **CLAIM_OK ≠ FIT_GO.**
**LOCK_OK=FREEZE_RECORDED** only after live md5s are written — **not**
post-fit lock. **PORT_OK source-only.** Live RBF still **`ebfe4a12`**.
**Cannot swap.** Do **not** start Quartus. Soft-skip ≠ PASS.
**P4-DISPLAY / P4-720P-MIX** stay **TODO**. No RGB565.

## slot720p24h claim (NOW STALE vs port land)

HEAD **`0e49a685`** (dirty vs origin OK). h prefix8:
`d0a450d9/d0deb1f7/b764e84c/d0a437e9/7a1435c6/f97c1912/a7cae451`

| file | h prefix8 | vs h (content) |
|------|-----------|----------------|
| present_core.sv | d0a450d9 | **DRIFT** (clk_ddr ports L139–140, L710–711) |
| fabric_ddr_reader.sv | d0deb1f7 | likely MATCH (not in PORT_OK edit set) |
| ddr_frame_store.sv | b764e84c | **DRIFT** (ports L82–83; no `emu.fabric_copy_`) |
| Plex.sv | d0a437e9 | **DRIFT** (present `.fabric_copy_*` L1101–1102) |
| Plex_720p24.qsf | 7a1435c6 | likely MATCH (QSF not in PORT_OK set) |
| Plex_clk_pix.sdc | f97c1912 | likely MATCH |
| ddr_frame_layout.hpp | a7cae451 | likely MATCH (`kPlex720p24PlxpPhys=0x3047F138`) |

Live prefix8 **not written** this ticket (no exec/`md5sum` in this worker).
Hasher: `/tmp/plex_quartus_720p24i.claim/freeze.py` (do **not** treat as FIT_GO).

## Not silicon

Lab **`ebfe4a12`** still Warning **10030** undriven. **FABRIC_PASS=NO.**
Do not bounce **13881**. No compact. No W-flag-off.

## Evidence

`/tmp/misterplex-agent-W-freeze-h.txt`
`/tmp/misterplex-agent-W-port-rtl.txt` PORT_OK
`/tmp/plex_quartus_720p24h.claim/src_md5.txt` (stale)
