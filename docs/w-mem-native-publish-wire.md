# w-mem — native 960×540 publish + atomic PLXG

## Honest status

| Layer | Claim | Evidence |
|-------|--------|----------|
| Host plan | FFmpeg storage **960×540**, `copy_bytes=777600`, Option-C map | `test_ddr_720p_abi` rc=0 |
| Host PLXG wire | **5 contiguous qwords** at bootstrap **0x300FF2C0** (not 3 temporal same-slot beats; not +0x130) | `plxg_record.hpp`, `fpga_spi::writePlxgRecord` |
| RTL latch/poller | `present_geom_latch` + `plxg_ddr_poller` in `Plex.sv` → `present_core.geom_*` | source + `test_rtl_invariants` |
| Device E2E | **NOT proven** — device down; no HDMI/doorbell liveness | parent power-cycle |

rd-duck STOP items addressed in source (await rd-duck re-audit before fit):

1. **m1 share** — `ddr_m1_subarb` latches stream/PLXG owner through response (no comb mux).
2. **PLXG seqlock** — invalidate q0 magic (`low32=0`) + DMB → body q1..q4 → q0 high then magic-last; poller re-reads q0 (`cnt_torn`). Without invalidate, retained-DDR + FPGA `last_seq=0` accepts torn body under old q0 (red twin in `test_ddr_720p_abi`).
3. **Mode exit** — legacy `makeDdrPublishPlan` programs `geom_enable=0` (seq-bumped).
4. **Raw geom** — over-max/unaligned rejected (`rt_raw_ok`); coded_w %16; no clamp-then-accept.

**Do not claim glass-proven native E2E until parent runs device. Do not grant fit until rd-duck clears.**

## Geometry split

| Field | 960×540 product |
|-------|-----------------|
| Storage / FFmpeg / plane bases | 960×540, strides 960/480, U=518400 V=648000, **777600 B** |
| Bank map | Option-C when payload > **usable 520192** (`0x30180000`/`0x180000`/`0x3047F000`) |
| DE canvas | 1280×720 (`h_de`/`v_de` in PLXG Q2) |
| PLXG bootstrap | fixed `0x300FF2C0` (legacy doorbell+0x2C0) — chicken-egg safe |

### Ownership (parent ruling)

- **w-path owns** `ddrFrameGeometryForFpgaPresent` / FFmpeg storage sizing.
- **w-mem owns** bank map, Option-C usable predicate, PLXG record, doorbell.
- Contract: 960×540→identity, 1280×720→identity, else product **624** canvas
  (never always-624 discarding 540; never identity-320 shear).
- B3 red-twin: PLXG coded 960×540 → U@**518400**; canvas 1280→U@**921600** is FAIL.

## Capacity predicate

Exact I420 bytes vs `bank_stride - 0x1000`. Raw geom reject in RTL
(`rt_raw_ok`). Tests: usable−1 / exact / +1 + 720×482 edge + tear/subarb/disable.

## Verify (build host)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-mem
./build/test_ddr_720p_abi; echo "true rc=$?"
python3 tests/unit/test_rtl_invariants.py; echo "true rc=$?"
make arm-plexd
```
