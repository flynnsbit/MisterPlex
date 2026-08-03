# DP 426→432 pad: present_x + host→mux oracle

**Lane:** w-path  
**Date:** 2026-08-03  
**Closes:** rd-duck “q3 display fix is only half-closure” (host half)

## Contract (host)

`ddrPadOnlyStorageGeometry(426,240)` / `ddrStorageGeometryForContent(426,240)`:

| Field | Value | Role |
|-------|------:|------|
| coded / stride | 432 | padded bank |
| presented / H_DE | 432 | canvas (bank) |
| display | 426 | visible content |
| present_x | 2 | **output placement** in canvas (q1 x0 + q4) |
| crop_left | 2 | storage crop (same inset) |
| crop_right | 4 | residual pad |

`present_x` is output placement, not a second name for storage crop alone.
Both q1 x0 and q4 crop carry inset 2 so a mux that latches either field wins.

## NEG

`ddrStorageGeometryForContent(432,240)` remains identity (display=432, crop=0).
Product DP path must pass **content 426**, not store-only 432.

## Oracle

`plxgMuxLatchVisual` + `plxgMuxIsPad426In432` in `plxg_record.hpp`:
host geom → `makeDdrPublishPlan` / `makePlxgRecordFromGeometry` → mux latch.
624/618 product fixture fails this predicate (cannot catch 432/432 alone).

## Tests + rc

```
./build/test_plxg_publish_geometry; echo "true rc=$?"   # 0
./build/test_resolve; echo "true rc=$?"                 # 0
./build/test_path_public_symbols; echo "true rc=$?"     # 0
./build/test_fpga_publish_ddr_frame; echo "true rc=$?"  # 0
make unit; echo "true rc=$?"                            # 0
```

## w-mem half (not this lane)

Mux/store must latch q3 display + q1 origin/q4 crop (coded≠display).
Host now emits the full tuple; fabric discard of q3 remains their fix.

## PLXG body (seqlock @ 0x300FF800)

- q1: content 426×240 @ x0=2  
- q2: H_DE=432, coded=432  
- q3: y_stride=432, display=426  
- q4: present_x=2, crop_left=2  
