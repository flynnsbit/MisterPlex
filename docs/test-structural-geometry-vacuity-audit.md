# Structural/geometry vacuity audit (W-GATE)

Audit date: 2026-07-28. Branch: `w-gate-inst-vacuity` off
`feat/disp-fix` at `19dde00`.

## Pre-registration

Highest-risk uncovered category selected before mutation runs: geometry facts
that cross a text/static boundary rather than a single compiled unit. Predicted:
`sound=3, vacuous=1, over-tight=0`. Actual before fixes:
`sound=3, vacuous=1, over-tight=0`. After the skip-inventory fix below:
`sound=4, vacuous=0, over-tight=0`.

## Raw geometry findings

| Probe | Literal operands compared | What it does not cover | Mutation evidence | Verdict |
| --- | --- | --- | --- | --- |
| Host/RTL DDR layout mirror | `host/libmisterplex/ddr_frame_layout.hpp` constants vs `fpga/Plex_MiSTer/rtl/ddr_frame_layout_params.svh` constants. | Does not prove either side is functionally consumed after synthesis. | `DDR_FRAME_CODED_WIDTH 624->640`; `GEOM_LAYOUT_WIDTH_RED_RC 1`; `FAIL: DDR frame layout mismatch: kPlex480pCodedWidth=624 but DDR_FRAME_CODED_WIDTH=640`; restore `rc=0`. | Sound. |
| ARM presenter raw stride | Source text in `media_player.cpp` must use `ddrGeometry.coded_width` for FFmpeg raw width and `display_width` only for crop/display. | Does not decode a frame or prove visual correctness. | `rawW = coded_width -> display_width`; `GEOM_ARM_RAWW_RED_RC 1`; `FAIL: present geometry/stride contract: FFmpeg rawvideo width must be the coded stride width (624)`; restore `rc=0`. | Sound. |
| Quartus scanout macro | `Plex.qsf` active macro must include `FRAME_W=640` while DDR coded width remains 624. | Does not run Quartus or prove post-fit hierarchy. | `FRAME_W=640 -> FRAME_W=624`; `GEOM_QSF_FRAMEW_RED_RC 1`; `FAIL: Quartus build must declare DDR_FRAME_STORE with 640x480 presented scanout`; restore `rc=0`. | Sound. |
| make-unit skip inventory geometry | Before fix, the live-PMS skip summary contained a hardcoded text claim `coded 624x480/display 618x480`. After fix, it derives from `ddr_frame_layout.hpp` and `--self-test` asserts the derived phrase appears. | Does not make the live PMS gate run; it only prevents a false coverage description when it skips. | Pre-fix in-memory mutation to `coded 640x480/display 640x480`: `GEOM_SKIP_INVENTORY_PREFIX_RED_RC 0`. Post-fix same hardcode: `GEOM_SKIP_INVENTORY_POSTFIX_RED_RC 1`; `missing derived geometry contract: coded 624x480/display 618x480`; restore `rc=0`. | Vacuous before fix; sound after fix. |

## New gate self-audits

| Gate | Literal operands compared | What it does not cover | Can it fail? |
| --- | --- | --- | --- |
| `scripts/check_rtl_module_instantiations.py` | Parsed RTL module declarations under `fpga/Plex_MiSTer/rtl/` vs modules reachable from product root `emu`, plus explicit reasons in `rtl/bench_only_modules.txt`. | It does not prove post-fit retention, useful dataflow, or that a bench-only classification is desirable; it makes non-product declarations explicit. | Yes. Renaming `nalu_scanner scan` to `nalu_scanner_removed scan` produced `RTL_MUTATION_RED_RC 1` and `UNINSTANTIATED_RTL_MODULE nalu_scanner ... parents=<none>`; restore `RTL_RESTORE_GREEN_RC 0`. |
| `scripts/check_pipe_exit_safety.py` | Tracked shell files under `scripts/` and `tests/` containing `| tail`, `| head`, `| grep`, or `| tee` vs an active `set ... pipefail`. | It does not cover ad-hoc terminal commands, Python subprocess pipelines, or remote shell strings beyond the local wrapper's pipefail. | Yes. Removing `set -o pipefail` from `tests/hw/hw_gate_common.sh` produced `PIPE_MUTATION_RED_RC 1` and `PIPE_WITHOUT_PIPEFAIL tests/hw/hw_gate_common.sh ops=grep,head sites=2`; restore `PIPE_RESTORE_GREEN_RC 0`. |
| `scripts/run_with_skip_summary.py --self-test` geometry inventory | The make-unit live-PMS skip `would_catch` string vs geometry derived from `ddr_frame_layout.hpp`. | It does not prove live PMS credentials are present or that the live stream passes; skip still reports `rc=77`/inventory when prerequisites are missing. | Yes. Hardcoding `coded 640x480/display 640x480` produced `GEOM_SKIP_INVENTORY_POSTFIX_RED_RC 1`; restore `GEOM_SKIP_INVENTORY_RESTORE_RC 0`. |

## Pipe grep report

The full scripts/tests scan found `files_with_pipes=40` and `pipe_sites=432`.
Only one tracked file lacked pipefail: `tests/hw/hw_gate_common.sh`, with
`ops=grep,head sites=2`. That helper now enables `set -o pipefail`; all scanned
pipe sites are covered by a local pipefail declaration.
