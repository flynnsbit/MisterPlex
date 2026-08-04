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

## PRODUCT_NO_STUB (w-nostub)

When `Plex.qsf` has active `PRODUCT_NO_STUB=1`, `decode_stub` moves from
required-REACHABLE to `teeth_non_reachable` and the gate resolves
`` `ifdef PRODUCT_NO_STUB `` in the instantiation graph. A QSF that claims the
macro while still instantiating the stub is RED. Soft-skip (77) is not a pass.

## Post-fit score vs 720p24 delivery

`make post-fit-score FIT_RPT=… STA_RPT=… RBF=…` proves **structure**: critical
modules survived fitting (`plex_rbf_build_id` ≥8 regs), STA has no negative
slack, prefit reachability still holds, and (when `PRODUCT_NO_STUB=1`)
`decode_stub` fitted resources are 0. It does **not** prove 720p24 delivery.
Fit/STA cannot see the ARM `/dev/mem` copy in `sendDdrFrame()` (~15 ms/frame)
or end-to-end DDR write + present bandwidth. A core that only “fits” can still
miss 24 fps if that copy stays serial with decode. Delivery evidence is a
separate, parent-run measurement (frame time with present+DDR write, or a
fabric DMA path that removes the ARM copy and is itself REACHABLE+fitted).

## Parent command list after exclusive fit

Run from the **exact tree that built the RBF** (sha frozen by provenance). Capture
each exit with `echo "true rc=$?"` outside any pipe. Soft-skip **77 is not PASS**.

```bash
make prefit-reachability; echo "true rc=$?"

make post-fit-hierarchy \
  FIT_RPT=path/Plex.fit.rpt \
  MAP_RPT=path/Plex.map.rpt \
  COMPILE_LOG=path/quartus.log
echo "true rc=$?"
# Require: plex_rbf_build_id registers >= 8 in FIT_HIERARCHY_TABLE

# When PRODUCT_NO_STUB=1 is active in Plex.qsf:
python3 scripts/check_quartus_fit_hierarchy.py \
  --fit-rpt path/Plex.fit.rpt \
  --config tests/fixtures/critical_fit_hierarchy_product_no_stub.json
echo "true rc=$?"
# Require: decode_stub status ABSENT_OK (0 fitted resources)

make post-fit-timing STA_RPT=path/Plex.sta.rpt; echo "true rc=$?"
make post-fit-timing-margin STA_RPT=path/Plex.sta.rpt; echo "true rc=$?"  # 77 = SKIP-NOT-PASS

python3 scripts/rbf_provenance.py emit --rbf path/Plex.rbf --builder parent-fit
python3 scripts/rbf_provenance.py verify --rbf path/Plex.rbf; echo "true rc=$?"

# One-shot wrapper (same rules; prints SCORE SUMMARY):
make post-fit-score \
  FIT_RPT=path/Plex.fit.rpt STA_RPT=path/Plex.sta.rpt \
  MAP_RPT=path/Plex.map.rpt COMPILE_LOG=path/quartus.log \
  RBF=path/Plex.rbf
echo "true rc=$?"

grep -nE 'plex_rbf_build_id|decode_stub' path/Plex.fit.rpt | head
```

`post-fit-score` structural PASS is **not** a 720p24 delivery PASS (ARM copy /
DDR write / present BW are outside fit/STA).
