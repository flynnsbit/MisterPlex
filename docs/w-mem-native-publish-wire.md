# w-mem — native 960×540 publish + atomic PLXG

## Honest status

| Layer | Claim | Evidence |
|-------|--------|----------|
| Host plan | FFmpeg storage **960×540**, `copy_bytes=777600`, Option-C map | `test_ddr_720p_abi` rc=0 |
| Host PLXG wire | **5 contiguous qwords** at bootstrap **0x300FF2C0** (not 3 temporal same-slot beats; not +0x130) | `plxg_record.hpp`, `fpga_spi::writePlxgRecord` |
| RTL latch/poller | `present_geom_latch` + `plxg_ddr_poller` in `Plex.sv` → `present_core.geom_*` | source + `test_rtl_invariants` |
| Device E2E | **NOT proven** — device down; no HDMI/doorbell liveness | parent power-cycle |

rd-duck STOP on 3-beat same-slot PLXG + tied-off latch is addressed in RTL/host source.
**Do not claim glass-proven native E2E until parent runs device.**

## Geometry split

| Field | 960×540 product |
|-------|-----------------|
| Storage / FFmpeg / plane bases | 960×540, strides 960/480, U=518400 V=648000, **777600 B** |
| Bank map | Option-C when payload > **usable 520192** (`0x30180000`/`0x180000`/`0x3047F000`) |
| DE canvas | 1280×720 (`h_de`/`v_de` in PLXG Q2) |
| PLXG bootstrap | fixed `0x300FF2C0` (legacy doorbell+0x2C0) — chicken-egg safe |

## Capacity predicate

Exact I420 bytes vs `bank_stride - 0x1000`. Unaligned geom rejected in RTL
(`rt_geom_aligned`). Tests: usable−1 / exact / +1 + 720×482 edge.

## Verify (build host)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-mem
./build/test_ddr_720p_abi; echo "true rc=$?"
python3 tests/unit/test_rtl_invariants.py; echo "true rc=$?"
make arm-plexd
```
