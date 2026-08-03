# w-mem — native 960×540 publish wired into daemon

## Honest status (parent item 1)

**Confirmed:** prior to this commit the measured +7.16 ms path was **not** what
`misterplexd` executed. Evidence:

- `media_player` sized FFmpeg via `ddrFrameGeometryForFpgaPresent` → always **624×480**
- `makeDdrFabricOwnedPublishPlan` had **no** runtime caller in `arm/misterplexd/`
- `sendDdrFrame` required `len == layout.frame_bytes` (full canvas)

rd-duck was right about the unwired path. Tip `c03afc46` already fixed
FpgaPresent→624 (not 1280); this commit **connects** the native plan.

## What landed

| Piece | Behaviour |
|-------|-----------|
| `ddrFfmpegGeometryForPresent` | 960×540 → storage 960×540; other fpga tiers → 624 canvas; never 1280 |
| `media_player` play start | builds `makePlex720pOutputFrom540pSourcePlan()`, activates Option-C layout |
| `publishDdrFrame` | native → `fpga_.publishDdrFabricOwned` (777600 + PLXG) |
| `sendDdrFrame` | `copy_bytes` may be &lt; canvas `frame_bytes`; PLXG beats before doorbell |
| E2E host test | `ddrNativeOptionCPublishReadbackOk` — 777600 → Option-C U@518400 V@648000 |

## Geometry split (unchanged contract)

| Field | 960×540 product |
|-------|-----------------|
| Storage / FFmpeg / PLXG geom | 960×540, strides 960/480, U=518400 V=648000, **777600 B** |
| Bank map | Option-C `0x30180000` / `0x180000` / `0x3047F000` |
| DE canvas | 1280×720 (scaler/glass; not FFmpeg size) |

## Fabric note (not this commit)

`Plex.sv` still leaves `present_core.geom_enable` at default **0**. ARM now
writes PLXG; fabric must wire PLXG→`geom_*` for runtime pitch. Fit gate is
host-side selector + native publish tests (below).

## Verify (build host)

```bash
cd /home/flynnsbit/Projects/MisterPlex-wt-mem
make $(pwd)/build/test_ddr_720p_abi $(pwd)/build/test_bitstream_ring_abi
./build/test_ddr_720p_abi; echo "true rc=$?"
./build/test_bitstream_ring_abi; echo "true rc=$?"
python3 tests/unit/test_rtl_invariants.py; echo "true rc=$?"
make arm-plexd; echo "true rc=$?"
```

Expect all `true rc=0`. Look for `NATIVE_E2E ... map=0x30180000 OK` and
daemon log line `NATIVE_PUBLISH tier=960x540 bytes=777600` on device (parent).
