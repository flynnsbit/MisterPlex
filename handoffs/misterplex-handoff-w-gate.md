# W-GATE handoff — MiSTerPlex

## 1. Identity

- Worker ID: W-GATE
- Branch: `w-gate-inst-vacuity`
- Worktree path: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-gate-inst-vacuity`
- Latest commit SHA: `73fcfb01c7a633ff765434d049a313ccd2e874c7`
- Latest commit subject: `test(decode): enforce unified core topology`
- Handoff path: `handoffs/misterplex-handoff-w-gate.md`

## 2. Assignment

I was the adversarial auditor/gate owner. My job was to find vacuous or product-absent evidence, build structural gates that prove RTL modules and decoder capabilities are actually product-reachable, audit newly load-bearing gates, and report raw measurements before conclusions.

The key task evolved from “every RTL module must be instantiated or explicitly bench-only” into “the product decoder must be complete and must use the binding topology: `stream_path -> h264_decode_core`, with `h264_decode_top` only as an intra sub-engine and `decode_stub` retired.”

## 3. What is DONE and PROVEN

### 3.1 RTL module instantiation gate

Files:

- `scripts/check_rtl_module_instantiations.py`
- `fpga/Plex_MiSTer/rtl/bench_only_modules.txt`
- `fpga/Plex_MiSTer/rtl/nondefault_config_modules.txt`
- `fpga/Plex_MiSTer/rtl/default_off_drop_modules.txt`
- Docs:
  - `docs/test-structural-geometry-vacuity-audit.md`
  - `docs/test-default-off-instantiation-and-scope-audit.md`
  - `docs/test-default-off-dropout-audit.md`

What it literally compares:

- Parses tracked RTL modules under `fpga/Plex_MiSTer/rtl/` plus product `Plex.sv`.
- Applies QSF/default macros and simple preprocessor/generate selection.
- Builds a source-level instantiation graph from product root `emu`.
- Requires every RTL module to be one of:
  - default product-reachable,
  - `NONDEFAULT_CONFIG_REACHABLE`,
  - classified default-off dropout,
  - or explicit bench-only.

Raw current command/result:

```bash
python3 scripts/check_rtl_module_instantiations.py
```

Current result at last run:

```text
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 default_reachable=41 nondefault_config_reachable=6 default_off_dropouts=15 default_off_real_decode_dropouts=14 bench_only=21 config_reachable=41 nondefault_variants=DDR_FRAME_STORE=<undefined>,DECODE_REAL_INTRA=1,FRAME_LINES_8=<undefined>,SDRAM_CL3=<undefined>,SDRAM_CLK_142=<undefined> root=emu
```

Important raw finding:

```text
DECODE_REAL_INTRA=0 -> 41 reachable
DECODE_REAL_INTRA=1 -> 29 reachable
ON-only: h264_decode_top, h264_intra4x4_pred, h264_intra16x16_pred
```

Dropout list (`reachable(DECODE_REAL_INTRA=0) - reachable(DECODE_REAL_INTRA=1)`):

```text
decode_stub
h264_chroma_epel_block_8x8
h264_chroma_epel_sample
h264_deblock_writeback_ctrl
h264_dpb_i420_addr
h264_dpb_mb_write_addr
h264_dpb_one_ref
h264_inter_mc_16x16
h264_inter_mc_part
h264_luma_qpel_block_16x16
h264_luma_qpel_sample
h264_luma_ref_tap_addr
h264_mv_pred_16x16
h264_mv_pred_part
h264_ref_clamp
```

Classification:

- `decode_stub`: stub-only scaffolding.
- Other 14: real decode/MC/MV/DPB/deblock/writeback machinery bypassed.

Specific residual/transform status I measured:

```text
h264_cavlc_residual_block off=False on=False dropout=False
h264_dequant4x4           off=True  on=True  dropout=False
h264_idct4x4              off=True  on=True  dropout=False
h264_recon4x4             off=True  on=True  dropout=False
h264_deblock_writeback_ctrl off=True on=False dropout=True
```

This corrected the parent’s hypothesis: transform modules were not dropping; CAVLC residual was absent from both product configs.

Red/green proof for instantiation/dropout gate:

```text
DROPOUT_MISSING_DECL_RED_RC 1
DEFAULT_OFF_DEFINE_DROP_UNDECLARED h264_deblock_writeback_ctrl defines=DECODE_REAL_INTRA=1

GENUINE_REACHABLE_DROPOUT_FALSE_RED_RC 1
RTL_MODULE_INSTANTIATION_FAIL: default-off drop declarations are not dropped by any discovered product-default-off define: h264_dequant4x4

DROPOUT_RESTORE_GREEN_RC 0
```

### 3.2 Pipe exit-code safety gate

Files:

- `scripts/check_pipe_exit_safety.py`
- `tests/hw/hw_gate_common.sh` fixed with `set -o pipefail`

Raw initial scan:

```text
40 shell files
432 pipe sites
1 unsafe fixed: tests/hw/hw_gate_common.sh
```

Current command/result:

```bash
python3 scripts/check_pipe_exit_safety.py
```

```text
PIPE_EXIT_SAFETY_OK files_with_pipes=40 pipe_sites=432
```

What it covers: shell files using `| tail`, `| head`, `| grep`, or `| tee` without local pipefail/PipeStatus handling.

What it does not cover: every possible pipeline command or language-specific subprocess pipeline.

### 3.3 Geometry/structural vacuity audit

Doc:

- `docs/test-structural-geometry-vacuity-audit.md`

Pre-registered prediction for selected checks was `sound=3 vacuous=1 over-tight=0`; post-fix result was `sound=4 vacuous=0 over-tight=0`.

Key example: ARM presenter raw stride gate literally checks source text uses `ddrGeometry.coded_width` for FFmpeg rawvideo width and display width only for display/crop.

Red proof:

```text
rawW = coded_width -> display_width
GEOM_ARM_RAWW_RED_RC 1
FAIL: present geometry/stride contract: FFmpeg rawvideo width must be the coded stride width (624)
restore rc=0
```

### 3.4 W-SWAP livelock gate audit

I audited W-SWAP’s `tests/unit/test_ddr_frame_store_swap_livelock.sh` and associated TB.

Conclusion: sound for its claimed property.

Literal comparison:

```text
top.frames_done >= frames_before_third + 1
```

What it does not cover: full video correctness, display capture, or all DDR/ring interactions.

Red proof observed/reported:

- Fault build with `DDR_FRAME_STORE_FAULT_PREP_INVALID_ONLY` fails with `no third swap`.
- Mutating `traceFinalDoorbell` to return true made red-check fail, proving it was not vacuous.

### 3.5 W-DEBLOCK scope gate audit

Audited W-DEBLOCK bS=4 scope gates:

- `tests/unit/test_p3_deblock_rtl_sim.sh`
- `tests/unit/test_stream_path_deblock_integration.sh`
- `tests/rtl/h264_deblock_tb.cpp`
- `tests/rtl/stream_path_deblock_tb.cpp`

Raw scope values measured/reported:

```text
h264_deblock_tb.cpp Scope: 641/16/4
stream_path_deblock_tb.cpp Scope: 128/120/4
```

Meaning: filtered samples / luma bS=4 / chroma bS=4 were nonzero. `Scope: 0` mutations went red.

### 3.6 Human-out-of-loop capture directive changes

Commit: `2313444 test(capture): retire human visual scoring`

Files changed include:

- `scripts/check_edges.py`
- `scripts/hw_visual_compare.py`
- `scripts/validate_playback_controls_hw.sh`
- `tests/hw/test_bank_release_visual.sh`
- `tests/unit/test_capture_rig.py`
- `tests/unit/test_hw_visual_compare.py`
- several HW scripts defaulting capture device.

Raw changes:

```text
device default: /dev/video4 -> /dev/video0
capture format: MJPEG 1280x720@60
raw YUYV: refused before device access
human PASS path: removed from bank-release visual gate
validate_playback_controls: no read/--yes human confirmation
```

Commands/results:

```bash
python3 tests/unit/test_capture_rig.py
python3 tests/unit/test_hw_visual_compare.py
python3 scripts/check_pipe_exit_safety.py
python3 tests/unit/test_unit_rollcall.py
make unit
```

All rc=0 at the time of that commit. I did not open `/dev/video0`; W-E2E owns the capture instrument.

Red/green proof:

```text
CAPTURE_DEFAULT_RED_RC=1
AssertionError: edge capture default must be /dev/video0, got /dev/video4
CAPTURE_DEFAULT_RESTORE_RC=0

RAW_REFUSAL_RED_RC=1
raw YUYV capture must be refused before touching the device
RAW_REFUSAL_RESTORE_RC=0
```

### 3.7 Decode completeness and topology gate

Commits:

- `0c5d367 test(decode): add completeness capability gate`
- `73fcfb0 test(decode): enforce unified core topology`

Files:

- `scripts/check_decode_completeness.py`
- `fpga/Plex_MiSTer/rtl/decode_capability_modules.txt`
- `tests/unit/test_decode_completeness_gate.py`
- `docs/test-decode-completeness-gate.md`
- Makefile target: `decode-completeness`
- Registered in `tests/unit/test_unit_rollcall.py`

Required categories in manifest:

```text
bitstream_entropy
residual_dequant_transform
intra_prediction
inter_prediction_mc_subpel
mv_prediction
dpb_reference_management
deblocking_writeback
```

Topology assertion now enforced:

```text
stream_path must directly instantiate h264_decode_core as the product decoder.
h264_decode_top may be reachable only as a descendant/sub-engine of h264_decode_core.
decode_stub must not be product-reachable.
h264_decode_skeleton must not be product-reachable.
```

Raw current product command/result:

```bash
python3 scripts/check_decode_completeness.py
```

It prints `Scope:` first and returns rc=1 on current tree, as intended baseline:

```text
Scope: decode-completeness product_configs=DECODE_REAL_INTRA=0,DECODE_REAL_INTRA=1 required_categories=7 manifest=fpga/Plex_MiSTer/rtl/decode_capability_modules.txt
DECODE_TOPOLOGY config=DECODE_REAL_INTRA=0 status=FAIL direct_stream_path_decoders=decode_stub required_product_decoder=h264_decode_core subengine_only=h264_decode_top retired=decode_stub problems=missing_product_decoder=h264_decode_core,stream_path_not_instantiating=h264_decode_core,retired_decoder_reachable=decode_stub,retired_decoder_direct_child=decode_stub
DECODE_COMPLETENESS_CONFIG config=DECODE_REAL_INTRA=0 status=FAIL reachable=41 decode_roots=decode_stub missing_categories=bitstream_entropy,residual_dequant_transform,intra_prediction,deblocking_writeback
DECODE_TOPOLOGY config=DECODE_REAL_INTRA=1 status=FAIL direct_stream_path_decoders=h264_decode_top required_product_decoder=h264_decode_core subengine_only=h264_decode_top retired=decode_stub problems=missing_product_decoder=h264_decode_core,stream_path_not_instantiating=h264_decode_core,subengine_used_as_product_decoder=h264_decode_top,subengine_reachable_outside_core=h264_decode_top
DECODE_COMPLETENESS_CONFIG config=DECODE_REAL_INTRA=1 status=FAIL reachable=29 decode_roots=h264_decode_top missing_categories=bitstream_entropy,residual_dequant_transform,intra_prediction,inter_prediction_mc_subpel,mv_prediction,dpb_reference_management,deblocking_writeback
DECODE_LINEAGE_COUNT count=4
```

Lineages measured by source graph:

```text
decode_stub: product for DECODE_REAL_INTRA=0 today, retired scaffolding
h264_decode_top: product only in unsafe =1 branch today; should be core sub-engine
h264_decode_core: chosen product decoder, currently dead/staged bench-only
h264_decode_skeleton: fourth lineage, dead/resource-estimation only
```

Measurement correction I reported: parent/W-DECODE said `h264_dpb_one_ref` was instantiated in four places. Parsed RTL parents are only `decode_stub` and `h264_decode_skeleton`. `h264_dpb.sv` defines it; `h264_decode_core.sv` mentions it in comments but does not instantiate it. Measurement wins.

Decode completeness unit command/result:

```bash
python3 tests/unit/test_decode_completeness_gate.py
```

```text
PASS current product decode configs hard-fail with four lineages reported
PASS synthetic complete graph satisfies every category
PASS synthetic missing-category mutation goes red
PASS synthetic retired-decoder topology mutation goes red
```

Synthetic proof commands/results:

```bash
python3 scripts/check_decode_completeness.py --synthetic-complete
```

rc=0, includes:

```text
DECODE_TOPOLOGY config=synthetic status=PASS direct_stream_path_decoders=h264_decode_core
DECODE_COMPLETENESS_OK synthetic complete graph satisfies every category
```

```bash
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-drop-category mv_prediction
```

rc=1, includes:

```text
DECODE_CAPABILITY config=synthetic category=mv_prediction status=FAIL present=<none> missing=h264_mv_pred_16x16,h264_mv_pred_part
```

```bash
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-bad-topology
```

rc=1, includes:

```text
DECODE_TOPOLOGY config=synthetic status=FAIL direct_stream_path_decoders=decode_stub ... problems=missing_product_decoder=h264_decode_core,stream_path_not_instantiating=h264_decode_core,retired_decoder_reachable=decode_stub,retired_decoder_direct_child=decode_stub
```

Targeted validation after latest topology commit:

```bash
python3 tests/unit/test_decode_completeness_gate.py    # rc=0
python3 tests/unit/test_unit_rollcall.py               # rc=0
python3 -m py_compile scripts/check_decode_completeness.py tests/unit/test_decode_completeness_gate.py  # rc=0
python3 scripts/check_pipe_exit_safety.py              # rc=0
```

Full `make unit` after topology gate update did not complete because resource preflight correctly refused active local Quartus processes. I did not override. Refusal output included active `quartus_sh` and `quartus_fit` under W-FIT’s docker compile.

## 4. What is IN PROGRESS

No uncommitted work. Worktree was clean before this handoff.

Most important next concrete step for successor:

- After W-DECODE/W-CAST/W-DEBLOCK/W-OSD land the unified decoder topology, rerun:

```bash
python3 scripts/check_rtl_module_instantiations.py
python3 scripts/check_decode_completeness.py
python3 tests/unit/test_decode_completeness_gate.py
python3 tests/unit/test_unit_rollcall.py
make unit   # only if resource preflight allows; do not override active Quartus refusal
```

Expected future green condition:

- `stream_path` directly instantiates `h264_decode_core`.
- `h264_decode_top` reachable only through `h264_decode_core`.
- `decode_stub` not product-reachable and likely removable once no tests/docs need it.
- All 7 capability categories pass in the same shippable product config.

## 5. What I TRIED THAT DID NOT WORK / refuted hypotheses

1. Parent hypothesis: transform/residual subtree was dropping when `DECODE_REAL_INTRA=1` and explained the 4/256 MB0 mismatch.
   - Measurement refuted the transform part: `h264_dequant4x4`, `h264_idct4x4`, and `h264_recon4x4` stayed reachable in both configs.
   - `h264_cavlc_residual_block` was reachable in neither product config; that is the likely residual-feed/product-absence problem.

2. Parent/W-DECODE claim: `h264_dpb_one_ref` instantiated in four places.
   - Parsed source graph refuted this. Actual instantiating parents were `decode_stub` and `h264_decode_skeleton` only. `h264_dpb.sv` defines it; `h264_decode_core.sv` had comments but no instantiation at my measurement point.

3. `DECODE_REAL_INTRA=1` looked like “turn on real decoder.”
   - Measurement showed it is an unsafe mutually-exclusive branch: gains intra-only modules but drops 14 real MC/MV/DPB/deblock modules.
   - The final topology ruling demotes `h264_decode_top` to sub-engine and makes `h264_decode_core` the only product decoder.

4. Human visual cards were previously acceptable as rc=77 UNSCORED or optional PASS via Q answers.
   - Ruling changed permanently. I removed scoreable human PASS paths I owned. Any future visual gate must be HDMI/Playwright-scored and distinguish no-signal, valid-black, valid-content.

5. Raw YUYV capture looked useful in old docs/scripts.
   - New measurement context says MS2109 on node-worker1 is MJPG-only. I changed active harness defaults to `/dev/video0` MJPG 1280x720@60 and added unit refusal for raw YUYV in `hw_visual_compare.py`. I did not open the device.

6. Full `make unit` after latest topology gate update could not be run to completion.
   - Not a test failure. Preflight refused active local Quartus. This refusal is correct per standing rules. Do not set `MISTERPLEX_ALLOW_LOW_MEMORY_TESTS=1`.

## 6. Gates I own

### 6.1 RTL instantiation gate

Path: `scripts/check_rtl_module_instantiations.py`

Run:

```bash
python3 scripts/check_rtl_module_instantiations.py
python3 scripts/check_rtl_module_instantiations.py --define DECODE_REAL_INTRA=0 --list-reachable
python3 scripts/check_rtl_module_instantiations.py --define DECODE_REAL_INTRA=1 --list-reachable
```

Current state: green for classification, but reports default-off/dropout warnings as structured output.

Red checks:

- Remove a real dropout declaration (e.g. `h264_deblock_writeback_ctrl`) from `default_off_drop_modules.txt` → rc=1 `DEFAULT_OFF_DEFINE_DROP_UNDECLARED`.
- Add a non-dropped module like `h264_dequant4x4` to `default_off_drop_modules.txt` → rc=1 stale/drop declaration.
- Remove bench-only/nondefault declarations for product-absent modules → rc=1 `UNINSTANTIATED_RTL_MODULE` or undeclared nondefault reachable.

### 6.2 Decode completeness/topology gate

Paths:

- `scripts/check_decode_completeness.py`
- `fpga/Plex_MiSTer/rtl/decode_capability_modules.txt`
- `tests/unit/test_decode_completeness_gate.py`
- `docs/test-decode-completeness-gate.md`

Run:

```bash
python3 scripts/check_decode_completeness.py
python3 tests/unit/test_decode_completeness_gate.py
make decode-completeness
```

Current product state: expected red rc=1 because current tree violates binding topology and completeness.

Current unit-wrapper state: green rc=0 because it asserts the expected red product baseline plus synthetic green/red proof.

Red checks:

```bash
python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-drop-category mv_prediction
# rc=1, category=mv_prediction status=FAIL

python3 scripts/check_decode_completeness.py --synthetic-complete --synthetic-bad-topology
# rc=1, retired decode_stub topology fails despite all capability modules present
```

Green check:

```bash
python3 scripts/check_decode_completeness.py --synthetic-complete
# rc=0
```

What it does not cover: semantic correctness, scheduling/control, signal correctness, throughput, or post-fit survival. It is source-graph structural reachability + topology only.

### 6.3 Pipe safety gate

Path: `scripts/check_pipe_exit_safety.py`

Run:

```bash
python3 scripts/check_pipe_exit_safety.py
```

Current state: green.

Red check: remove `set -o pipefail` from a shell file containing unsafe `| tail/head/grep/tee`, or add such a pipe to a shell script without pipefail/PipeStatus handling. It should report the unsafe site.

### 6.4 Capture rig static guard

Paths:

- `tests/unit/test_capture_rig.py`
- `scripts/check_edges.py`
- `scripts/hw_visual_compare.py`
- `tests/unit/test_hw_visual_compare.py`

Run:

```bash
python3 tests/unit/test_capture_rig.py
python3 tests/unit/test_hw_visual_compare.py
```

Current state: green.

Red checks:

- Change `check_edges.DEFAULT_DEV` back to `/dev/video4` → `test_capture_rig.py` rc=1.
- Remove raw YUYV refusal from `hw_visual_compare.py` → `test_hw_visual_compare.py` rc=1 on `--input-format yuyv422` refusal check.
- Reintroduce `HUMAN_RESULT=PASS` or `PLEASE ANSWER` in `tests/hw/test_bank_release_visual.sh` → `test_capture_rig.py` rc=1.

### 6.5 Unit rollcall

Path: `tests/unit/test_unit_rollcall.py`

Run:

```bash
python3 tests/unit/test_unit_rollcall.py
```

Current state after decode gate registration:

```text
UNIT_ROLLCALL_OK actual_prereqs=33 expected_prereqs=33 actual_commands=94 protected_commands=91 expected_commands=91 actual_ignored_commands=3 expected_ignored_commands=3
```

Red check: add/remove a unit-unlocked command without updating expected list → `UNREGISTERED_COMMAND` or `MISSING_COMMAND`.

## 7. Interfaces agreed with other workers

### 7.1 Binding decode topology

Agreed/ratified topology:

```text
stream_path -> h264_decode_core     # single product decoder
h264_decode_top                     # intra-MB sub-engine only inside core
decode_stub                         # retired scaffolding, not product
h264_decode_skeleton                # dead/resource-estimation only
```

W-GATE gate enforces this structurally in `check_decode_completeness.py`.

### 7.2 W-DECODE

W-DECODE stated chosen topology:

- Product decoder converges on `decode_stub` / `h264_decode_core` lineage preserving MC/DPB/ref/deblock machinery.
- `h264_decode_top` becomes sub-engine, not stream_path replacement.
- `DECODE_REAL_INTRA` may select real intra inside the core but must not change the product decoder subtree or remove inter/MC/DPB/deblock modules.

W-GATE replied/encoded:

- Structural acceptance requires product reachable set include `h264_intra4x4_pred`, `h264_intra16x16_pred`, `h264_inter_mc_*`, `h264_mv_pred_*`, `h264_dpb_one_ref`, and `h264_deblock_writeback_ctrl` in the same product config.

### 7.3 W-SWAP

W-SWAP should build MC/DPB/writeback under `h264_decode_core`, not the old intra-only branch. W-GATE’s topology gate will fail if `stream_path` still points at `decode_stub` or `h264_decode_top` directly.

### 7.4 W-CAST

W-CAST update received:

```text
real P frame parser coverage: 1170/1170 MBs
groups=331 skipped=928 inter=197 intra=45 P16x16=197
IDR coverage: 300/300 MBs
fixed macroblock_bit_offset 22 vs expected 24 by consuming P ref-index/list-mod syntax
added MODE_MB_LAYER for non-skipped MB after skip run
```

W-GATE interpretation:

- This may satisfy parts of `bitstream_entropy` once parser modules become product-reachable under `h264_decode_core`.
- Standalone parser tests do not count for product presence; completeness gate only cares product reachability.
- CAVLC residual block is currently product-reachable in neither current config; attach under `h264_decode_core`.

### 7.5 W-DEBLOCK

W-DEBLOCK asked for exact dropout command. I provided:

```bash
python3 scripts/check_rtl_module_instantiations.py --define DECODE_REAL_INTRA=0 --list-reachable
python3 scripts/check_rtl_module_instantiations.py --define DECODE_REAL_INTRA=1 --list-reachable
```

Dropout set is `reachable(=0) - reachable(=1)`. Current gate direct output includes:

```text
DEFAULT_OFF_DEFINE_DROPS_REAL_DECODE_MODULE h264_deblock_writeback_ctrl defines=DECODE_REAL_INTRA=1
```

W-DEBLOCK should land deblock/writeback in `h264_decode_core` lineage. Completeness category `deblocking_writeback` requires:

```text
h264_deblock_bs
h264_deblock_thresholds
h264_deblock_edge
h264_deblock_edge_pipe
h264_deblock_writeback_ctrl
```

### 7.6 W-OSD

W-OSD update received after latest W-GATE commit:

- Branch `w-osd-neighbor`, commit `c5784d0`.
- Replaces hardcoded `h264_decode_top` external luma neighbours with `h264_intra_nb_ctx` outputs.
- Context remains PRE-deblock only; DPB/ref remains POST-deblock.
- Added `first_mb_in_slice` semantic availability so storage-valid samples across slice boundaries are unavailable.
- W-GATE script result in W-OSD branch: `DEFAULT_OFF_DEFINE_REACHABLE_MODULE h264_intra_nb_ctx defines=DECODE_REAL_INTRA=1`.
- With `--define DECODE_REAL_INTRA=1 --list-reachable`, `h264_intra_nb_ctx`, `h264_decode_top`, `h264_intra4x4_pred`, `h264_intra16x16_pred` reachable together.
- Denominator in W-OSD nb raster gate: `1170` MBs/frame; PASS checks=252.

W-GATE interpretation:

- Good for neighbour correctness but still in unsafe default-off intra-only branch until merged into `h264_decode_core` lineage.
- Future successor should consider adding `h264_intra_nb_ctx` to `decode_capability_modules.txt` under `intra_prediction` or a new neighbour-context category once W-OSD lands in this branch. Do not add it before it exists/reaches product in this branch or the current baseline changes.

### 7.7 W-E2E / capture instrument

W-GATE notified W-E2E:

- `/dev/video0` is the sole local MS2109 MJPG 1280x720@60 capture node.
- `/dev/video1` is a decoy.
- `/dev/video4` default is stale.
- W-GATE will not open `/dev/video0`; W-E2E owns capture device leasing/scoring.

## 8. Open risks and things I believe are wrong

1. `decode_stub` probably can be deleted only after `h264_decode_core` is product-reachable and all tests/fixtures referencing `decode_stub` are either migrated or explicitly archaeological. Today it is still default product path; deletion now would break current product graph.

2. `h264_decode_skeleton.sv` is a fourth decode-like lineage but should remain dead/resource-estimation only. It instantiates many required modules and can fool “module exists / testbench passes” reasoning. The topology gate now fails if it becomes product-reachable.

3. The strict capability manifest requires all modules in a category. This is intentional but may need updates during refactor/rename. If a category is genuinely implemented by a new module, update the manifest and red/green proof; do not suppress failures.

4. Current `h264_decode_core` may be described as product skeleton in comments, but source graph says it is not product-reachable. Measurement wins until `stream_path` instantiates it.

5. Full `make unit` is not currently revalidated after latest topology-gate commit because active local Quartus made resource preflight refuse after 20 attempts. This is correct behavior, not a reason to override. Targeted tests passed.

6. The latest W-OSD neighbor work is not merged into W-GATE branch. My gate may need updating after merge if `h264_intra_nb_ctx` becomes part of the chosen core topology.

7. The decode completeness gate is structural. A green future result will prove categories are in the product graph, not that the decoder works. It must be paired with W-CAST/W-DECODE/W-DEBLOCK semantic gates and hardware/capture evidence.

8. I stored a repository memory: product decoder topology is `stream_path -> h264_decode_core`; `h264_decode_top` is only an intra sub-engine; `decode_stub` retired. Future agents should rely on this unless measurement refutes it.
