# Prefit reachability + RBF provenance (fit-release gate)

**What it proves:** (1) named critical modules are both listed in `files.qip` and
**instantiated on a root-reachable path** from `sys_top`/`emu` (static elaboration
graph — catches the CAVLC-in-QIP-but-pruned class); (2) every shipped RBF has a
manifest binding `rbf_md5 → git_commit + dirty + qip_files`, verified at deploy
(exit 8 if missing). Fabric module `plex_rbf_build_id` stamps commit prefix into
the bitstream; post-fit survival is a **separate** stage (`make post-fit-hierarchy
FIT_RPT=...`) and is not claimed by the prefit gate.

**What it does not prove:** functional correctness of decode/present, STA, area,
or that a fitted RBF still contains the stamp until FIT_RPT is scored.

Run: `make prefit-reachability`, `make rbf-what-built MD5=...`, unit twins
`test_rbf_provenance.sh` / `test_plex_rbf_build_id_rtl_sim.sh`. Soft-skip (77) is
never a pass.
