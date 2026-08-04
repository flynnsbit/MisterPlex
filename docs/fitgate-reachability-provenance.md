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
Fit/STA cannot see the ARM uncached publication memcpy in `sendDdrFrame()`
(~15 ms/frame) or end-to-end DDR write + present bandwidth. A core that only
“fits” can still miss 24 fps if that copy stays serial with decode.

**rd-duck corrections (binding on this gate):**
- Sweep116 **49% idle was sampled BEFORE decode**, not during it
  (`Memory/scratch/busyfix.sh`: `idle_pct` then `decode`). Do **not** budget a
  free core for overlap during decode until same-window `/proc/stat`+`wait4`.
- “Fabric DMA and ARM never touches the frame” is **too strong**. Software
  decode/rawvideo still writes pixels. DMA can retire the **uncached
  publication memcpy only**, and only after pinned contiguous/SG +
  cache-coherency contract.
- Prefer a **dynamic-base direct fabric reader** over a source→bank mover
  (mover adds read+write traffic).

Delivery evidence remains parent HW measurement; this score never sets
`DELIVERY_PROVEN=1`.

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

## Delivery path stamp (`plex_delivery_path_stamp`)

Fabric-visible class bit for Sweep 118:

| path_class[1:0] | Meaning |
|---|---|
| `01` | **ARM_COPY** (default) — HPS uncached publication memcpy (`sendDdrFrame`) |
| `10` | **FABRIC_DMA** claimed (`FABRIC_FRAME_DMA=1`) — publication path only; not delivery-proven |

Parent-measured serial deficit (Sweep 118; do not re-derive casually):

- frame budget @24 fps = 41.667 ms
- decode = 32.705 ms/frame
- `T_copy_arm` = 14.978 ms/frame (publication memcpy CPU time, not a payload rate)
- serial shortfall = **6.016 ms/frame**

`post-fit-score` always prints `DELIVERY_CLASS=STRUCTURAL_ONLY` /
`DELIVERY_PROVEN=0`. Structural FIT PASS ≠ 720p24 delivery.

### Fit-slot blockers (both required)

Unless the parent **explicitly** resolves the conflict in writing, treat **both**:

1. **w-nostub reclaim** on main + post-fit `decode_stub` ABSENT under `PRODUCT_NO_STUB`
2. **w-osd** full 1280×720 real L4 reader proof at 20:90 clock ratio **with injected stalls**

as hard blockers on releasing the exclusive Quartus slot. Parent wording that
names only nostub does **not** clear the w-osd blocker (rd-duck).
