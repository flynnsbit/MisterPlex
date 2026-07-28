# W-DECODE handoff

## 1. Identity

- Worker ID: W-DECODE
- Branch: `w-decode-hour27`
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27`
- Latest commit: `ddb7c9776fe6aa2cb06ea04eb1ab26e549187373` (`feat(hw): feed intra neighbours through decode core`)
- Push state: pushed twice; final `git status --short` was clean before this handoff file was written. This handoff is under `.copilot-logs/` because this runtime forbids file operations in `/tmp`.

## 2. Assignment

I was asked to make the real H.264 FPGA decoder product-reachable in the native MiSTerPlex datapath without deleting the existing inter/MC/DPB/deblock machinery, and to prove reachability with structural gates rather than standalone benches. My specific ownership was consumer-side/product wiring: `stream_path.sv`, `h264_decode_core.sv`, the intra sub-engine handoff, and the W-OSD/W-CAST seams needed by that path.

## 3. What is DONE and PROVEN

### Committed product-root wiring

Commit `cd9fe29 feat(hw): root product decode in core`:
- `stream_path.sv` now instantiates `h264_decode_core` as the product decode root.
- `stream_path.sv` no longer directly instantiates `h264_decode_top`.
- `h264_decode_core.sv` instantiates `h264_decode_top` as `u_product_intra_mb`, an intra-MB sub-engine.
- `decode_stub` remains only as a diagnostic frame-store painter/scaffolding path, not as the chosen decoder.
- Added W-CAST-style luma residual/mode pulse seam on `h264_decode_core`.

Commit `ddb7c97 feat(hw): feed intra neighbours through decode core`:
- Added/ported `h264_intra_nb_ctx.sv` from W-OSD.
- Added `rtl/h264_intra_nb_ctx.sv` to `fpga/Plex_MiSTer/files.qip`.
- Instantiated `h264_intra_nb_ctx` inside `h264_decode_core`, feeding `h264_decode_top` neighbour ports.
- Removed external hardcoded neighbour ports from `stream_path -> h264_decode_core`.
- Removed `h264_intra_nb_ctx` from `bench_only_modules.txt` because it is now product-reachable.
- Updated core/stream-path test filelists and expected-red manifest entries.

### Raw structural/source measurements

From `w-decode-hour27` after `ddb7c97`:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27 && \
python3 - <<'PY'
from pathlib import Path
s=Path('fpga/Plex_MiSTer/rtl/stream_path.sv').read_text()
c=Path('fpga/Plex_MiSTer/rtl/h264_decode_core.sv').read_text()
print('stream_path_has_h264_decode_core=', 'h264_decode_core' in s)
print('stream_path_has_h264_decode_top=', 'h264_decode_top' in s)
print('core_has_h264_decode_top=', 'h264_decode_top' in c)
print('core_has_h264_intra_nb_ctx=', 'h264_intra_nb_ctx' in c)
PY
```

Measured:
- `stream_path_has_h264_decode_core= True`
- `stream_path_has_h264_decode_top= False`
- `core_has_h264_decode_top= True`
- `core_has_h264_intra_nb_ctx= True`

Official instantiation gate:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27 && \
python3 scripts/check_rtl_module_instantiations.py > .copilot-logs/nb_module_inst_final.log 2>&1; rc=$?; echo rc=$rc; cat .copilot-logs/nb_module_inst_final.log
```

Measured:
- `rc=0`
- `RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=50 bench_only=18 root=emu`

Important limitation: that official gate rooted at `emu` is not enough while `decode_stub` is still instantiated, because stub reachability can mask modules missing from `h264_decode_core`. See section 5.

Core-subtree measurement I ran after W-GATE corrected my overbroad claim:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27 && python3 - <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location('check_rtl_module_instantiations','scripts/check_rtl_module_instantiations.py')
mod=importlib.util.module_from_spec(spec); sys.modules[spec.name]=mod; spec.loader.exec_module(mod)
paths=mod.git_files('fpga/Plex_MiSTer/rtl')+[mod.PRODUCT_TOP]
mods=mod.parse_modules(paths)
graph=mod.instantiation_graph(mods)
reach_core=mod.reachable_from('h264_decode_core', graph)
keys=['h264_decode_top','h264_intra_nb_ctx','h264_mv_pred_16x16','h264_mv_pred_part','h264_inter_mc_16x16','h264_inter_mc_part','h264_dpb_one_ref','h264_deblock_writeback_ctrl','h264_luma_qpel_block_16x16','h264_luma_qpel_sample','h264_chroma_epel_block_8x8','h264_chroma_epel_sample','h264_dpb_i420_addr','h264_dpb_mb_write_addr','h264_luma_ref_tap_addr','h264_ref_clamp']
print('core_subtree_reachable_count', len(reach_core))
for name in keys:
    print(f'{name}={name in reach_core}')
PY
```

Measured:
- `core_subtree_reachable_count 15`
- Present under core: `h264_decode_top`, `h264_intra_nb_ctx`, `h264_mv_pred_16x16`, `h264_mv_pred_part`, `h264_luma_qpel_sample`, `h264_chroma_epel_sample`, `h264_dpb_i420_addr`, `h264_dpb_mb_write_addr`
- Missing under core: `h264_inter_mc_16x16`, `h264_inter_mc_part`, `h264_dpb_one_ref`, `h264_deblock_writeback_ctrl`, `h264_luma_qpel_block_16x16`, `h264_chroma_epel_block_8x8`, `h264_luma_ref_tap_addr`, `h264_ref_clamp`

### Targeted gates that passed after neighbour/core integration

All commands below were run from `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27`; logs are in `.copilot-logs/` where applicable.

- `make quartus-sv-subset` → rc=0
- `make define-parity` → rc=0
- `python3 scripts/check_rtl_module_instantiations.py` → rc=0, `rtl_modules=68 reachable=50 bench_only=18 root=emu`
- `python3 tests/unit/test_h264_intra_nb_ctx_verilator.py` → rc=0
  - Scope denominator printed by gate: 1170 MBs/frame.
  - Red checks include stub neighbours, swapped chroma U/V, and false edge/slice availability.
- `tests/unit/test_stream_path_real_intra_rtl_sim.sh` → rc=0
- `tests/unit/test_stream_path_recon_integration.sh` → rc=0
- `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh` → rc=0
- `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh` → rc=0
- `tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh` → rc=0
- `git diff --check` → rc=0

Full `make unit` was attempted after neighbour integration:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-decode-hour27 && make unit > .copilot-logs/nb_make_unit.log 2>&1; rc=$?; echo rc=$rc; tail -80 .copilot-logs/nb_make_unit.log
```

Measured:
- `rc=2`
- It progressed through decode/RTL-adjacent gates and failed later in a host test: `FAIL: path callback key mismatch: /library/metadata/3` from `test_companion_eof`.
- No override was used. I did not treat full unit as green.

### Displayed-pixel / bit-exact measurements from earlier in the same assignment

- The first direct `DECODE_REAL_INTRA` stream-path integration changed displayed pixels versus stub: `76796/76800` full-frame pixels differed in the gate. That proved the old path was not dead logic, but it also proved the path was not bit-exact/product-complete.
- MB0 exactness initially measured only `4/256` exact RGB565 pixels compared with standalone/golden.
- Ruling out neighbours and RGB conversion, I found the real stream-path delta: only block0 residual was fed, blocks 1-15 were zero, and all i4 modes were forced to DC.
- After temporary all-16 residual/mode wiring, MB0 improved to `74/256`, still not bit-exact.
- Denominator context: coded 624x480 = 39x30 = 1170 MBs/frame. MB0 is only 1/1170 of one frame; standalone `20/20 MBs` is only 1.7% of one 1170-MB frame.

## 4. What is IN PROGRESS

No uncommitted RTL edits are in progress. The worktree was clean before writing this handoff.

The next concrete step is not more W-DECODE-local wiring until W-GATE/W-SWAP decide or land the core-completeness gate and MC/DPB/deblock seams. Specifically, the product proof must distinguish:

- modules reachable from `emu` only because `decode_stub` still exists, versus
- modules reachable through the chosen `h264_decode_core` subtree.

Files most likely touched next:
- `scripts/check_rtl_module_instantiations.py` or a companion W-GATE completeness gate, to support core-subtree/category checks.
- `fpga/Plex_MiSTer/rtl/h264_decode_core.sv`, to instantiate or route missing MC/DPB/deblock modules under the core.
- `fpga/Plex_MiSTer/rtl/stream_path.sv`, only if removing/isolating `decode_stub` diagnostic painter is approved.

## 5. What I TRIED THAT DID NOT WORK

1. Parent initially hypothesised MB0 mismatch was missing neighbour context. I measured it directly and refuted it for MB0:
   - standalone and stream-path MB0 both had left/top/topright/topleft unavailable and neutral 128 samples.
   - Neighbours matter for MB>0, but they did not explain MB0 `4/256`.

2. I also checked whether RGB565 conversion caused MB0 mismatch. It did not:
   - golden-derived/presented RGB565 MB0 still only had `4/256` exact pixels.
   - Actual delta was residual/mode feed, not colour conversion.

3. The old `DECODE_REAL_INTRA` topology was the wrong product shape:
   - `DECODE_REAL_INTRA=1` gained intra prediction by making `h264_decode_top` the stream-path decoder, but it dropped inter/MC/DPB/deblock modules.
   - With live content measured elsewhere as 343 P-slices to 7 I-slices and one real P-frame having 928 skipped, 197 inter, 45 intra of 1170 MBs, intra-only cannot decode the product stream.

4. My first reachability claim after `ddb7c97` was overbroad and W-GATE corrected it:
   - I said MC/DPB/deblock modules were product-reachable from `emu`.
   - Measurement under `h264_decode_core` root showed several of those modules were reachable only through `decode_stub` or not under core at all.
   - This is now recorded as a risk and must shape the next gate.

5. Treating standalone/module tests as proof is unsafe:
   - `h264_decode_top` was standalone-good but product-wrong/intra-only.
   - `h264_cavlc_residual_block` exists but W-CAST measured divergence at real MB0 block11 high-nC/high-TC; all-16 producer is not handoff-ready.
   - A green bench that does not prove product reachability should not be accepted.

6. I did not run Quartus, deploy, or open HDMI capture. Those remain W-FIT/W-E2E-owned resources.

## 6. Gates I own

### `scripts/check_rtl_module_instantiations.py`

Run:
```bash
python3 scripts/check_rtl_module_instantiations.py
```
Current green state:
- rc=0
- `RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=50 bench_only=18 root=emu`

Red-check used for neighbour reachability:
- Temporarily add `h264_intra_nb_ctx: temporary mutation to prove reachable modules cannot be bench-only` to `fpga/Plex_MiSTer/rtl/bench_only_modules.txt`.
- Run `python3 scripts/check_rtl_module_instantiations.py`.
- Expected red: rc=1, failure saying bench-only modules are now reachable.
- Restore the file; rerun; rc=0.

Limitation:
- This gate is necessary but insufficient while `decode_stub` remains under `emu`; it cannot alone prove modules are under `h264_decode_core`.

### `tests/unit/test_stream_path_real_intra_rtl_sim.sh`

Run:
```bash
tests/unit/test_stream_path_real_intra_rtl_sim.sh
```
Current green state: rc=0.

What it now covers:
- stream-path/core topology and real-intra/core compile linkage, not full bit-exact product decode.
- It should ensure `stream_path` uses `h264_decode_core`, no direct `h264_decode_top`, and core contains `h264_decode_top`.

How to make fail:
- Reintroduce direct `h264_decode_top` instantiation in `stream_path.sv`, or remove `h264_decode_top` from `h264_decode_core.sv`.

### `tests/unit/test_h264_intra_nb_ctx_verilator.py`

Run:
```bash
python3 tests/unit/test_h264_intra_nb_ctx_verilator.py
```
Current green state: rc=0.

What it compares:
- Expected semantic neighbour availability and sample outputs from `h264_intra_nb_ctx` against raster/picture-edge/slice-boundary expectations over the coded 624x480 geometry; denominator is 1170 MBs/frame.

What it does not cover:
- Full decode correctness.
- MC/DPB/deblock.
- Actual HDMI output.
- CAVLC all-16 residual correctness.

How to make fail:
- Manifest red entries added in `tests/expected_red_manifest.json`:
  - `h264_intra_nb_ctx_stub_neighbors`
  - `h264_intra_nb_ctx_swap_chroma_uv`
  - `h264_intra_nb_ctx_edge_available`
- The harness checks expected-red mutations for stub neighbours, swapped chroma U/V, and false edge/slice availability.

### Core RTL benches updated by W-DECODE

Run:
```bash
tests/unit/test_h264_decode_core_writeback_rtl_sim.sh
tests/unit/test_h264_decode_core_p16z_rtl_sim.sh
tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh
tests/unit/test_stream_path_recon_integration.sh
```
Current green state: each rc=0 in targeted validation after neighbour integration.

How to make fail:
- Remove required core filelist entries such as `h264_intra_nb_ctx.sv` or `h264_decode_top.sv`.
- Break core writeback handshake/recon outputs.
- For topology-specific scripts, remove `h264_decode_core` from `stream_path.sv`.

### Static gates

Run:
```bash
make quartus-sv-subset
make define-parity
git diff --check
```
Current green state:
- all rc=0 after `ddb7c97`.

## 7. Interfaces agreed with other workers

### W-CAST residual/mode producer seam

Consumer is `h264_decode_core`.

Agreed signal contract:
- `luma4x4_valid`
- `luma4x4_idx[3:0]`
- `luma4x4_qp[5:0]`
- `luma4x4_total_coeff[4:0]`
- `luma4x4_trailing_ones[1:0]` optional/available
- `luma4x4_coeff_zigzag[0:15]` signed `[15:0]`
- stable `intra4x4_modes[0:15]`, packed as `i4_modes[63:0]`/array depending on local module shape.

Coefficient order is zigzag/scan order, not raster/dequant order. I confirmed this is the right consumer-side contract because `h264_dequant4x4` performs the scan-to-raster mapping internally.

Ownership:
- W-CAST owns producer/parser/CAVLC correctness.
- W-DECODE/core consumes pulses and must fail honestly if blocks/modes are missing.

Current status:
- W-CAST does not yet have a handoff-ready all-16 producer. Their measurement: real MB0 blocks 0-10 matched, block11 diverged (`expected end=563`, RTL ended `550`), blocks 12-15 then misdecoded, final end `763` vs expected `853`.

### W-OSD intra neighbour seam

Consumer is `h264_decode_core -> h264_decode_top`.

Agreed luma outputs from neighbour context:
- `mb_avail_left`
- `mb_avail_top`
- `mb_avail_topright`
- `mb_avail_topleft`
- `nb_top[0:15]`
- `nb_left[0:15]`
- `nb_topleft`
- `nb_topright[0:3]`

Availability is semantic, not merely storage-valid:
- picture edges unavailable.
- above-right false at right picture edge.
- `first_mb_in_slice` prevents storage-valid samples across slice boundaries being treated as available.
- MB0 external neighbours are unavailable/128.

Ordering contract:
- Intra prediction consumes PRE-deblock reconstructed neighbours only.
- DPB/reference/MC consumes POST-deblock output only.
- Do not feed DPB/post-deblock samples into `h264_intra_nb_ctx`.

Current implementation note:
- `h264_decode_core` owns `h264_intra_nb_ctx` internally.
- For now, block-level incremental feed into the context is not used (`block_valid` tied low); whole-MB commit uses `product_intra_recon_valid` and reconstructed MB arrays.
- Chroma is currently neutral 128 in W-DECODE core wiring; luma is the active seam.

### W-SWAP MC topology agreement

- MC work must target `h264_decode_core` under `stream_path`.
- `h264_decode_top` is only intra leaf/sub-engine.
- `decode_stub` must not satisfy MC/DPB/deblock proof.
- The proof must show MC/DPB/ref/deblock modules reachable through the core subtree or via W-GATE’s updated core-aware completeness gate.

### W-DEBLOCK seam

- Deblock/writeback must land under `h264_decode_core`.
- `h264_deblock_writeback_ctrl` currently measured missing from the `h264_decode_core` subtree, despite being reachable elsewhere via old/stub/skeleton lineages.
- PRE-deblock reconstructed neighbours feed intra; POST-deblock writes feed DPB/reference.

## 8. Open risks and anything I believe is wrong

1. Biggest risk: `decode_stub` still being instantiated under `stream_path` can make `emu`-root reachability look greener than the real core topology. W-GATE’s corrected core-subtree/category gate is required before anyone claims complete product decode.

2. `h264_decode_core` is not a complete decoder yet. Missing under core as measured: `h264_inter_mc_16x16`, `h264_inter_mc_part`, `h264_dpb_one_ref`, `h264_deblock_writeback_ctrl`, `h264_luma_qpel_block_16x16`, `h264_chroma_epel_block_8x8`, `h264_luma_ref_tap_addr`, `h264_ref_clamp`.

3. Full product decode is not watchable and not bit-exact. Current work is product-reachable seam/topology, not a display PASS.

4. Intra-only correctness is insufficient for live content. The measured content denominator and distribution matter: 1170 MBs/frame; one P-frame measured by W-CAST had 928 skipped, 197 inter, 45 intra. MC/DPB/deblock are product requirements, not optional polish.

5. CAVLC all-16 residual is blocked on a real decoder bug in W-CAST’s side. Do not silently zero missing residual blocks; that recreated the original `4/256` failure mode.

6. The old idea of enabling `DECODE_REAL_INTRA` as a stream-path topology switch is wrong. It deletes too much decode machinery. If `DECODE_REAL_INTRA` remains, it must not change the top-level decoder subtree.

7. Full `make unit` is not green in this worktree because of `test_companion_eof` path callback mismatch. I did not diagnose it because it is outside W-DECODE scope and the handoff request said stop new work.

8. I could not write the handoff to `/tmp/misterplex-handoff-w-decode.md` because this runtime has a higher-priority security rule forbidding all `/tmp` file operations. I wrote it to `.copilot-logs/misterplex-handoff-w-decode.md` instead.
