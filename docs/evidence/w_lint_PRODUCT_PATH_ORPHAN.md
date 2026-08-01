# w-lint — product-path orphan gate + telemetry provenance

**Branch:** `w-lint-gate-integrity`  
**Host-only.** No device / Quartus.

## Pattern

Code (or RTL) that is **fully unit-tested and green** but **does not drive the product path** creates false confidence — the suite is green about code the product never runs.

Parent trio:

| # | Artifact | Evidence on this tree |
|---|----------|------------------------|
| 1 | `rawPipeDesynced` / `rawPipePhaseOffset` | **NOT_DEFINED** on this branch (defined on w-geom / w-avsync trees). Synthetic RBG plants them test-only → RED, then arm-ref → GREEN. If merged test-only, tier-1 fails. On trees where `arm/misterplexd/media_player.cpp` calls them, they are **not** orphans. |
| 2 | `host/libmisterplex/cadence.hpp` | `should_advance_unique` / `unique_frames_in` / `content_index_at` — **only** `tests/unit/test_cadence.cpp` outside the header. |
| 3 | `fpga/.../present_cadence.sv` | Instantiated in `present_core.sv:115`. Outputs: `advance` → `stat_advance` only; `cont_i` → `colorbars` + stat. **DDR bank swap** is async vsync re-latch in `ddr_frame_store.sv` (`vsync_pulse && swap_pending`), not `advance_unique`. |

## Gate

`tests/unit/test_product_path_orphan.py`

- **C++:** free/inline APIs under `host/libmisterplex` whose only non-definition refs are under `tests/`.
- **SV:** modules whose **output** ports never reach a product sink (`ddr_frame_store`, `frame_store`, …). `colorbars` + `stat_*` do not count as product sinks.
- **Allowlist:** short, justified; **FORBIDDEN** to allowlist the parent trio (meta-guard).
- **Tier-1 (CI hard-fail):** cadence symbols + any SV dead-fanout of this class + rawPipe* if test-only.
- **Tier-2 (inventory every run):** other test-only lib APIs (printed; `--strict-all` redlines them too). Not silent.

### Measured true rc

```
python3 tests/unit/test_product_path_orphan.py --self-test
  RBG_REAL_HIT cxx:should_advance_unique|unique_frames_in|content_index_at
  RBG_REAL_HIT sv:present_cadence consumers=['colorbars','stat_*']
  RBG_SYNTH_RED_HIT rawPipeDesynced|rawPipePhaseOffset|orphan_cadence
  RBG_SYNTH_GREEN_OK after product wire
  SELFTEST_OK
true rc=0

python3 tests/unit/test_product_path_orphan.py
  TIER1=4 (3× cadence cxx + present_cadence)
  TIER2_INVENTORY=46
  PRODUCT_PATH_ORPHAN_FAIL
true rc=1
```

**Tree is intentionally RED on tier-1** until product wires cadence into the DDR path or the dead path is removed — not allowlisted.

Wired in `Makefile` `unit-unlocked` (self-test + full). Rollcall `expected_commands=130`.

## Telemetry provenance (task 2)

`tests/unit/test_telemetry_provenance_guard.py`

Flags:

- `to_string(vfps|pfps|…).substr(0,N)` truncation  
- `av_drift_ms` without `av_drift_role=servo_error_not_lipsync`  
- bare `23.976` / `24000/1001` without provenance vocabulary  

### Product fix landed

`arm/misterplexd/media_player.cpp` media 1 Hz line:

- full `%.3f` rates (no substr)  
- `vfps_src=measured` `pfps_src=measured`  
- `av_drift_role=servo_error_not_lipsync` `av_drift_src=measured`  
- `fps_src=caller_supplied` for stream N/D  

```
python3 tests/unit/test_telemetry_provenance_guard.py --self-test  → true rc=0
python3 tests/unit/test_telemetry_provenance_guard.py             → true rc=0
```

## What parent should still do on device

- Confirm display-side skips vs daemon residual (out of scope here).  
- When promoting: identity still requires PLXC/HDMI (`video_regression` rc=2 without).  
- Cadence/product path: design choice — wire `advance_unique` into bank swap, or stop testing it as if it were the DDR present path.
