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
2b. **PLXG seq restart-safe + ABA** — before invalidate, read retained q0 seq and seed `useSeq=max(sw,retained)+1`. Not only stale-disable (N==1 reject): FPGA reset `last_seq=0` + daemon restart reusing seq=1 is an ABA tear — poller snap q0=1, host body-update, recommit q0=1, reread matches mixed body. Invalidate alone insufficient; commit seq must differ from retained (`plxgAbaSameSeqRecommitAcceptsTorn` / `plxgAbaIncrementSeqRejectsTornThenFreshCommits`).
3. **Mode exit** — legacy `makeDdrPublishPlan` programs `geom_enable=0` (seq-bumped).
4. **Raw geom** — over-max/unaligned rejected (`rt_raw_ok`); coded_w %16; no clamp-then-accept.
5. **Line-cache frame gen** — tags are not only `{bank,line}`: each accepted doorbell/SPI bumps that bank's gen and clears matching slots; fill commit requires gen match; geom/map change bumps both gens and clears all. Without this, same-bank re-publish while pending (or bank0→1→0 with top lines still cached) swaps stale prep pixels. Gate: `tests/unit/test_ddr_frame_store_line_gen.sh` (FAULT `LINE_CACHE_FRAME_GEN=0` → stale Y; GOOD gen=1 → fresh Y + geom gen bump).
6. **Freeze twin isolation** — gen-invalidate punches holes in a full prep set, which can mask the sticky/recycle freeze class (9eb1431a). `test_ddr_frame_store_scanout_freeze.sh` builds broken with `LINE_CACHE_FRAME_GEN=0` and good with gen=1 so both gates stay honest.
7. **RTL selector oracle** — `test_ddr_frame_store_selector.sh` elaborates real `ddr_frame_store` and checks usable−exact / over / 720×482 / 960×540→Option-C U@518400 / storage≠DE canvas / w%16 reject. FAULT `FORCE_LEGACY_BANK_MAP` REPRO. Host-only edges are not sufficient (rd-duck).

**Line-gen scope note (rd-duck 2026-08-03):** present_core clamps `rd_y` to LAST in VBlank; bank0→1→0 top-stale is not proven inevitable from VBlank alone. Independent executable REPRO remains: same-bank re-publish while pending (`line_gen` fault Y=65). Keep gen tags; do not treat as sole fit blocker.

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
