# W-DEBLOCK handoff

Note: parent corrected the handoff path after the initial `/tmp` request. This committed handoff lives at `handoffs/misterplex-handoff-w-deblock.md` in the W-DEBLOCK worktree.

## 1. Identity

- Worker ID: W-DEBLOCK
- Branch: `w-deblock-seam`
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam`
- Latest code commit SHA before handoff-only commit: `7225e00 fix(deblock): reach writeback from decode core`
- Handoff commit: the commit containing this file; see final reply / `git log -1` for its exact SHA.
- Also relevant commits on this branch:
  - `b39fc16 test(deblock): extend seam scope to full P frame`
  - Earlier accepted seam commit from this assignment line: `a4ed0b9` (deblock/DPB same-phase ref promotion fix, swapped PRE/POST tap red-check, QPc trap)

## 2. Assignment

I was W-DEBLOCK. My scope was the H.264 in-loop deblocking filter and its seam with reconstructed-neighbour/intra prediction on one side and DPB/MC reference publication on the other. In my own words:

- Verify stale defect reports before changing RTL.
- Make deblock gates non-vacuous: real sample modifications, `Scope:` first, and red/green proof.
- Fix deblock→DPB ordering so MC never sees a half-filtered reference.
- Prove tap direction: intra neighbours consume PRE-deblock reconstructed samples; DPB/MC consume POST-deblock samples only after filtered writeback and frame boundary.
- Extend seam scope from a 2-MB synthetic proof to a real full 624x480 P frame (`39x30 = 1170 MBs`), including skipped MBs.
- After topology ruling, make `h264_deblock_writeback_ctrl` reachable from `h264_decode_core`, not merely from retired/default scaffolding.

## 3. What is DONE and PROVEN

### 3.1 Stale defect verification

Measured, not assumed:

- I found no `h264_deblock_scheduler` module in this branch at the time of work.
- I found no measured `.is_chroma(1'b0)` scheduler tie-off to fix because the named scheduler did not exist.
- I did not manufacture that defect. Instead I added gates/invariants that would catch chroma being unreachable or vacuous later.

### 3.2 bS=4 and chroma/QPc non-vacuity

Done before current compaction and retained in branch:

- bS=4 luma and chroma paths are exercised with non-zero modified samples.
- Gate prints scope before PASS.
- Real MB-golden fixture QP range was measured as `25..25`; this is inside the QPc trap because below QP 30 QPy/QPc agree.
- Synthetic sweep covers QP `4..51`.
- High-QP chroma trap uses `QPy/QPc=40/36` and red-check catches substituting QPy for QPc.

Command:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam
tests/unit/test_p3_deblock_rtl_sim.sh > build/w-deblock-p3-deblock.log 2>&1; rc=$?; echo rc=$rc
```

Measured rc: `0`.

Key raw output:

```text
Scope: real_p_bs_mb_boundary_edges=2271/2271 real_p_mbs=1170/1170 skipped_mbs=928 skipped_edges_scored=1949 inter_mbs=197 inter_edges_scored=533 intra_mbs=45 intra_edges_scored=160 bs_counts=160/0/270/43/1798 left_top_unfiltered_edges=69 coded=624x480 display=618x480 crop_padding_samples_in_coded_frame=4320 qp_range=3..33
Scope: filtered_samples=641 luma_bS4=16 chroma_bS4=4 real_fixture_qp_range=25..25 synthetic_qp_range=4..51 chroma_qpc_trap_qpy_qpc=40/36
OK h264_deblock RTL sim: bS, threshold, luma, chroma, pipe-latency, writeback-DPB contract, mb_golden, edge-order drift
FAIL expected skipped MB bS red-check: skipped edges bypassed=1949
OK h264_deblock RTL red-check: skipped MB bS bypass failed real-P scope
FAIL expected chroma QPc red-check: QPy=40 substituted_for_QPc=36
OK h264_deblock RTL red-check: chroma QPy/QPc substitution failed high-QP trap
FAIL deblock multi-frame drift first_mismatch=66 got=101 want=100 got_fnv=0x43c73250 want_fnv=0xc8c278ae
OK h264_deblock RTL red-check: swapped edge order produced drift mismatch
FAIL deblock writeback: MB commit before all filtered samples wb=1 order_error=1
OK h264_deblock RTL red-check: early MB commit before filtered samples failed
FAIL deblock writeback: DPB ref ready before frame boundary wb=1 addr=1169 ready=1
OK h264_deblock RTL red-check: early DPB ref_ready fault failed
```

What that covers:

- Real P-frame MB-boundary deblock strength over `2271/2271` MB-boundary edges.
- Real frame denominator: `1170` MBs.
- Skipped MBs: `928/1170` MBs; skipped edges scored: `1949`.
- Inter MBs: `197`; intra MBs: `45`.
- It does NOT cover every internal 4x4 edge in the full real frame; this particular full-frame bS scope is MB-boundary edges.

### 3.3 Full-frame deblock→DPB seam scope including skipped MBs

Command:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam
tests/unit/test_p3_dpb_mc_rtl_sim.sh > build/w-deblock-p3-dpb.log 2>&1; rc=$?; echo rc=$rc
```

Measured rc: `0`.

Key raw output:

```text
Scope: product_i420_writes=1536 luma_window=441/441 chroma_windows=81/81/81 mc_pixels=256/64/64 frame_fraction=4/1170 coded=624x480 nals=15
OK real RTL sim: h264_dpb_mc product RTL nals=15 i420_writes=1536 luma_window=441 chroma_windows=81/81 mc_pixels=256/64/64 part_modes=16x8/8x16/8x8/8x4/4x8/4x4 fixture=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264
Scope: seam_filtered_samples=768 seam_committed_mbs=2/1170 frame_fraction=0.001709 nals=15
OK h264_dpb_mc deblock-DPB seam: filtered samples precede wb_valid; terminal wb_valid precedes frame_done/ref_ready nals=15 fixture=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264
Scope: full_frame_seam_filtered_mbs=1170/1170 filtered_samples=449280 skipped_filtered_mbs=928/928 skipped_filtered_samples=356352 inter_mbs=197 intra_mbs=45 syntax_groups=331 qp_range=3..33 coded=624x480 display=618x480 crop_padding_samples_written=4320
OK h264_dpb_mc full-frame deblock-DPB seam: every real P-frame MB, including skipped MBs, writes 384 POST-deblock samples before DPB ref promotion
Scope: tap_pre_neighbour_samples=4 tap_post_dpb_samples=4 frame_fraction=1/1170 coded=624x480
OK h264_dpb_mc pre/post tap direction: intra neighbours consume PRE-deblock; DPB writes POST-deblock
FAIL h264_dpb_mc RTL: skipped MB bypassed filtered writeback mb=2 wb=0 order_error=1
OK h264_dpb_mc RTL red-check: skipped MB bypass failed full-frame seam
FAIL h264_dpb_mc RTL: pre/post tap direction intra neighbour used wrong tap row=0 got=163 want_pre=35 forbidden_post=163
OK h264_dpb_mc RTL red-check: swapped pre/post taps failed seam
FAIL h264_dpb_mc RTL: deblock-DPB seam MB commit before all filtered samples wb=1 order_error=1 ref_ready=0
OK h264_dpb_mc RTL red-check: deblock early MB commit fault failed seam
FAIL h264_dpb_mc RTL: deblock-DPB seam terminal commit/ref_ready order wb=1 addr=1169 pulse=1 ref_ready=0
OK h264_dpb_mc RTL red-check: deblock early frame_done fault failed seam
FAIL h264_dpb_mc RTL: early reference publication before frame boundary
OK h264_dpb_mc RTL red-check: early reference publication fault failed golden
```

What that proves:

- Full real P-frame denominator is `1170/1170` MBs.
- Every MB, including all `928/928` skipped MBs, contributes `384` post-deblock I420 samples before DPB promotion.
- Total full-frame samples written/scored: `449280` (`1170 * 384`).
- Skipped samples: `356352` (`928 * 384`).
- Cropped display vs coded frame is measured: coded `624x480`, display `618x480`, crop-padding samples written inside coded frame `4320`. This means deblock/writeback covers coded pixels; display crop is not treated as partial MB geometry.
- Tap gate literally compares small PRE neighbour sample set against POST DPB sample set; it covers only `1/1170` MB for tap direction but has a deliberate swapped-tap red-check.

### 3.4 Deblock/DPB ordering fix

The seam invariant is implemented by `h264_deblock_writeback_ctrl` in `fpga/Plex_MiSTer/rtl/h264_deblock.sv`:

- `filtered_sample_valid` increments per-MB sample count.
- `filtered_mb_valid` only commits when `sample_count == SAMPLES_PER_MB` unless fault macro is enabled.
- Terminal `filtered_mb_valid && filtered_frame_done && filtered_mb_is_ref` sets a pending reference.
- `frame_boundary && ref_pending` emits one-cycle `ref_ready_pulse`.
- Early MB commit and early ref-ready have fault macros/red-checks.

### 3.5 Decode-core product-lineage reachability

Latest commit `7225e00` did this:

- Added `h264_deblock_writeback_ctrl` instantiation inside `h264_decode_core.sv`.
- Added `ST_COMMIT` and `ST_FRAME_BOUNDARY` states to core writeback flow.
- Changed core `frame_done` to be driven by `deblock_ref_ready_pulse`, not same-cycle raw terminal sample write.
- Added `--root` to `scripts/check_rtl_module_instantiations.py`.
- Registered this command in `Makefile` and `tests/unit/test_unit_rollcall.py`:

```bash
python3 scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl
```

Green command:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam
python3 scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl > build/w-deblock-core-reach2.log 2>&1; rc=$?; echo rc=$rc
```

Measured rc: `0`.

Raw output:

```text
REQUIRED_RTL_MODULE_REACHABLE h264_deblock_writeback_ctrl root=h264_decode_core
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=11 bench_only=24 root=h264_decode_core
```

Red-proof command used:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam
cp fpga/Plex_MiSTer/rtl/h264_decode_core.sv build/h264_decode_core.sv.reach_bak2
python3 - <<'PY'
from pathlib import Path
p=Path('fpga/Plex_MiSTer/rtl/h264_decode_core.sv')
s=p.read_text()
old='h264_deblock_writeback_ctrl #('
if old not in s:
    raise SystemExit('target instantiation not found')
p.write_text(s.replace(old, 'h264_deblock_writeback_ctrl_missing #(', 1))
PY
set +e
python3 scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl > build/w-deblock-core-reach-red2.log 2>&1
red_rc=$?
set -e
cp build/h264_decode_core.sv.reach_bak2 fpga/Plex_MiSTer/rtl/h264_decode_core.sv
python3 scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl > build/w-deblock-core-reach-green2.log 2>&1
green_rc=$?
echo red_rc=$red_rc green_rc=$green_rc
```

Measured output:

```text
red_rc=1 green_rc=0
--- red ---
REQUIRED_RTL_MODULE_UNREACHABLE h264_deblock_writeback_ctrl file=fpga/Plex_MiSTer/rtl/h264_deblock.sv parents=decode_stub,h264_decode_skeleton
RTL_MODULE_INSTANTIATION_FAIL: required RTL modules are not reachable from h264_decode_core
--- green ---
REQUIRED_RTL_MODULE_REACHABLE h264_deblock_writeback_ctrl root=h264_decode_core
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=11 bench_only=24 root=h264_decode_core
```

Important distinction:

- Measured: `h264_deblock_writeback_ctrl` is now reachable from root `h264_decode_core`.
- Assumed/externally owned: `h264_decode_core` will be wired into `stream_path` as product decoder by W-DECODE. I did not wire `stream_path` to core. Default `emu` reachability still reports the old default shape and is not sufficient final proof after the topology ruling.

### 3.6 Decode-core writeback gate

Command:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam
tests/unit/test_h264_decode_core_writeback_rtl_sim.sh > build/w-deblock-core-wb-rerun.log 2>&1; rc=$?; echo rc=$rc
```

Measured rc: `0`.

Key raw output:

```text
Scope: decode_core_writeback_mbs=2/8 samples=768 frame_done_seen=1
OK h264_decode_core writeback scoreboard: 2 MBs, 768 native-I420 samples landed at DPB addresses; terminal frame_done observed
FAIL h264_decode_core writeback scoreboard: write count 0 < 384
OK h264_decode_core writeback red-check: dropped writeback fault failed scoreboard
```

What it covers:

- Small decode-core writeback geometry `64x32`, denominator `8` MBs.
- Writes two MBs, `768` native-I420 samples.
- Confirms terminal `frame_done` is observed after new core deblock controller path.
- Does not cover full 1170 MBs; that full denominator is covered by the separate DPB seam gate above.

### 3.7 Existing decode-core P16/real-slice gates still green after adding deblock RTL dependency

Commands:

```bash
tests/unit/test_h264_decode_core_p16z_rtl_sim.sh > build/w-deblock-core-p16z.log 2>&1; rc=$?; echo rc=$rc
tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh > build/w-deblock-core-real-slice.log 2>&1; rc=$?; echo rc=$rc
```

Measured rc for both: `0`.

P16z key raw output:

```text
OK h264_decode_core p16x16 real-P scoreboard: 3 MBs syntax+MV-neighbor+CAVLC-residual path 384x3 exact clipped pred+16Y+8C scheduled-residual samples landed at DPB addresses; reads=63744 clipped_samples=56 clip_low=10 clip_high=46 rbsp_request_offsets=37/50/63 chroma_right_clamp_reads=96 cycles=131005 timeout_cycles=222704; nonterminal frame_done stayed low
EXPECTED_RED h264_decode_core_p16z_drop_pred: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_drop_residual: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_perturb_mv: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_bad_rbsp_req: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_drop_mv_neighbor: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_drop_scheduled_residual: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_drop_last_luma_residual: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_drop_last_chroma_residual: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_swap_scheduled_coeff: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_swap_chroma_scheduled_coeff: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_swap_chroma_read: rc=1 matched 1 manifest substring(s)
EXPECTED_RED h264_decode_core_p16z_swap_chroma_residual: rc=1 matched 1 manifest substring(s)
```

Real-slice key raw output:

```text
test_h264_decode_core_real_slice: OK real-content disabled-loop-filter I420 slice reconstructed 2 P16 MBs exact; residual_nonzero=768 uv_distinct_samples=128 chroma_right_clamp_reads=32 varied-real-content=0->1@(5,0) right-edge-chroma-clamp=0->1@(38,7)
EXPECTED_RED h264_decode_core_real_slice_swap_chroma_read: rc=1 matched 1 manifest substring(s)
OK h264_decode_core real-slice red-check: swapped U/V chroma read failed real-content scoreboard
```

### 3.8 Static/lint/full-suite validation

Commands and measured rc:

```bash
scripts/rtl_lint.py > build/w-deblock-rtl-lint.log 2>&1; rc=$?; echo rc=$rc
# rc=0

make quartus-sv-subset > build/w-deblock-quartus-sv-subset.log 2>&1; rc=$?; echo rc=$rc
# rc=0

make unit-rollcall > build/w-deblock-unit-rollcall.log 2>&1; rc=$?; echo rc=$rc
# rc=0

git diff --check > build/w-deblock-diff-check2.log 2>&1; rc=$?; echo rc=$rc
# rc=0

make unit > build/w-deblock-core-make-unit-final.log 2>&1; rc=$?; echo rc=$rc
# rc=0
```

Full `make unit` key raw lines:

```text
UNIT_ROLLCALL_OK actual_prereqs=33 expected_prereqs=33 actual_commands=92 protected_commands=89 expected_commands=89 actual_ignored_commands=3 expected_ignored_commands=3 makefile=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam/Makefile
python3 /home/flynnsbit/Projects/MisterPlex/.worktrees/w-deblock-seam/scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl
REQUIRED_RTL_MODULE_REACHABLE h264_deblock_writeback_ctrl root=h264_decode_core
GATE_SKIP_SUMMARY total=2 critical=1 high=1 advisory=0
GATE_SKIP CRITICAL live-pms-baseline-profile: reason=... set PLEX_BASE, PLEX_TOKEN, and MISTERPLEX_BASELINE_KEY ...
GATE_SKIP HIGH skip-not-pass: reason=OK red-check: live PMS wrapper missing deps return SKIP-NOT-PASS rc=77
```

The `make unit` rc was truly captured from `make`, redirected to a file, not through a pipe. The two skips are existing live-PMS/skip-wrapper conditions, not W-DEBLOCK gates.

## 4. What is IN PROGRESS

Nothing is mid-edit in my worktree. Status was clean before writing this handoff:

```text
## w-deblock-seam...origin/w-deblock-seam
7225e00 fix(deblock): reach writeback from decode core
```

Concrete next step for successor if continuing W-DEBLOCK:

1. Rebase/merge against whatever branch wires `h264_decode_core` into `stream_path`.
2. Re-run `python3 scripts/check_rtl_module_instantiations.py --root emu --require h264_decode_core --require h264_deblock_writeback_ctrl` or the W-GATE equivalent once `emu -> stream_path -> h264_decode_core` is intended to be true.
3. If `h264_decode_top` becomes a sub-engine inside `h264_decode_core`, verify PRE-deblock neighbour inputs do not accidentally come from the POST-deblock DPB path.

No uncommitted source files are touched.

## 5. What I TRIED THAT DID NOT WORK

- Parent's earliest stated defect `h264_deblock_scheduler hardcodes .is_chroma(1'b0)` did not exist in this branch when measured. There was no `h264_deblock_scheduler` to edit. Correct action was to report no finding and add gates to prevent chroma support becoming tied off later.
- A real fixture with QP `25..25` was insufficient to prove chroma QPc correctness. Below QP 30, QPy/QPc tables agree, so substituting QPy could pass. I added the synthetic `QPy/QPc=40/36` trap because the real fixture alone could not catch it.
- Testbench green was not enough for product presence. `h264_deblock_writeback_ctrl` was reachable through `decode_stub`, but after parent topology ruling that was only retired scaffolding. I had to add an explicit root check for `h264_decode_core`.
- First attempt to run `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh` after adding the core instantiation failed with Verilator `MODMISSING: Cannot find file containing module: 'h264_deblock_writeback_ctrl'`. The design edit was present, but the core test scripts did not compile `h264_deblock.sv`. I fixed the scripts by adding `h264_deblock.sv` to writeback, P16z, and real-slice core tests.
- Red-proving core reachability by renaming the instantiation worked and showed an important nuance: after mutation, `h264_deblock_writeback_ctrl` still had parents `decode_stub,h264_decode_skeleton`, but was unreachable from `h264_decode_core`. That is the exact failure class the new gate is intended to catch.
- I did not use HDMI capture. These are RTL/Verilator/structural gates and do not require W-E2E's `/dev/video0` instrument.

## 6. Gates I own

### `tests/unit/test_p3_deblock_rtl_sim.sh`

Run:

```bash
tests/unit/test_p3_deblock_rtl_sim.sh > build/w-deblock-p3-deblock.log 2>&1; rc=$?; echo rc=$rc
```

Current green: rc `0`.

Important scopes:

- `real_p_bs_mb_boundary_edges=2271/2271`
- `real_p_mbs=1170/1170`
- `skipped_mbs=928`, `skipped_edges_scored=1949`
- `bs_counts=160/0/270/43/1798` = bS4/bS3/bS2/bS1/bS0
- `filtered_samples=641`, `luma_bS4=16`, `chroma_bS4=4`
- Real fixture QP `25..25`; synthetic QP `4..51`; QPc trap `40/36`

How to make it fail:

- Skipped-MB bS bypass fault: the script runs expected-red and should print `FAIL expected skipped MB bS red-check: skipped edges bypassed=1949` then `OK ... failed real-P scope`.
- QPc substitution fault: expected-red should print `FAIL expected chroma QPc red-check: QPy=40 substituted_for_QPc=36`.
- Swapped edge order: expected-red should print `FAIL deblock multi-frame drift ...`.
- Early MB commit: expected-red should print `FAIL deblock writeback: MB commit before all filtered samples ...`.
- Early ref-ready: expected-red should print `FAIL deblock writeback: DPB ref ready before frame boundary ...`.

### `tests/unit/test_p3_dpb_mc_rtl_sim.sh`

Run:

```bash
tests/unit/test_p3_dpb_mc_rtl_sim.sh > build/w-deblock-p3-dpb.log 2>&1; rc=$?; echo rc=$rc
```

Current green: rc `0`.

Important W-DEBLOCK scopes:

- Legacy small seam: `seam_committed_mbs=2/1170`, samples `768`.
- Full seam: `full_frame_seam_filtered_mbs=1170/1170`, samples `449280`.
- Skipped full seam: `skipped_filtered_mbs=928/928`, samples `356352`.
- Tap direction: `tap_pre_neighbour_samples=4`, `tap_post_dpb_samples=4`, frame fraction `1/1170`.

How to make it fail:

- Skipped MB bypass: expected-red prints `FAIL h264_dpb_mc RTL: skipped MB bypassed filtered writeback ...`.
- PRE/POST swap: expected-red prints `FAIL h264_dpb_mc RTL: pre/post tap direction intra neighbour used wrong tap ... forbidden_post=...`.
- Early MB commit: expected-red prints `FAIL h264_dpb_mc RTL: deblock-DPB seam MB commit before all filtered samples ...`.
- Early frame_done/ref_ready: expected-red prints `FAIL h264_dpb_mc RTL: deblock-DPB seam terminal commit/ref_ready order ...`.
- Early reference publication: expected-red prints `FAIL h264_dpb_mc RTL: early reference publication before frame boundary`.

### `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh`

Run:

```bash
tests/unit/test_h264_decode_core_writeback_rtl_sim.sh > build/w-deblock-core-wb-rerun.log 2>&1; rc=$?; echo rc=$rc
```

Current green: rc `0`.

Scope: `decode_core_writeback_mbs=2/8 samples=768 frame_done_seen=1`.

How to make it fail:

- Script builds a `+define+H264_DECODE_CORE_FAULT_DROP_WB` red-check.
- Expected-red output: `FAIL h264_decode_core writeback scoreboard: write count 0 < 384`, then `OK h264_decode_core writeback red-check: dropped writeback fault failed scoreboard`.

### `scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl`

Run:

```bash
python3 scripts/check_rtl_module_instantiations.py --root h264_decode_core --require h264_deblock_writeback_ctrl
```

Current green:

```text
REQUIRED_RTL_MODULE_REACHABLE h264_deblock_writeback_ctrl root=h264_decode_core
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=11 bench_only=24 root=h264_decode_core
```

How to make it fail:

- Rename the instantiation token in `h264_decode_core.sv` from `h264_deblock_writeback_ctrl #(` to another module name.
- Expected red rc: `1`.
- Expected output includes `REQUIRED_RTL_MODULE_UNREACHABLE h264_deblock_writeback_ctrl ... parents=decode_stub,h264_decode_skeleton`.

### `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh` and `tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh`

These are not deblock-specific originally, but I modified their RTL file lists to include `h264_deblock.sv` because `h264_decode_core` now instantiates the writeback controller.

Run:

```bash
tests/unit/test_h264_decode_core_p16z_rtl_sim.sh > build/w-deblock-core-p16z.log 2>&1; rc=$?; echo rc=$rc
tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh > build/w-deblock-core-real-slice.log 2>&1; rc=$?; echo rc=$rc
```

Current green: both rc `0`.

How to make them fail:

- Existing scripts already run many expected-red defines (drop pred/residual, perturb MV, bad RBSP, swap chroma reads/residuals). See section 3.7 raw output.
- If `h264_deblock.sv` is removed from their RTL arrays while core still instantiates `h264_deblock_writeback_ctrl`, Verilator fails with `MODMISSING`.

## 7. Interfaces agreed with other workers

### W-SWAP / MC and DPB side

Agreed contract, acknowledged by W-SWAP after `7225e00`:

1. `filtered_sample_valid` accounts for all post-deblock samples for an MB before `filtered_mb_valid`/`wb_valid` for that MB.
2. Terminal `filtered_mb_valid + filtered_frame_done/wb_valid` occurs while DPB `ref_ready` is still `0`.
3. A later `frame_boundary` produces a one-cycle deblock `ref_ready_pulse`.
4. `h264_dpb_one_ref` consumes only that post-boundary pulse as `frame_done` and exposes `ref_ready` after promotion.
5. MC fetch gates on committed post-deblock DPB visibility, not raw terminal commit and not PRE-deblock local recon.

Signal names W-SWAP said are acceptable and I preserved:

- `filtered_sample_valid`
- `filtered_mb_valid`
- `filtered_frame_done`
- `frame_boundary`
- `ref_ready_pulse`

### W-OSD / intra neighbour side

Agreed contract:

- `h264_intra_nb_ctx` stores/serves PRE-deblock reconstructed samples only.
- DPB/reference remains POST-deblock and must not feed this module.
- Intra prediction consumes PRE-deblock local recon neighbours.
- DPB/MC consumes POST-deblock after filtered writeback and frame-boundary promotion.

W-OSD reported branch `w-osd-neighbor`, commit `c5784d0`, with `h264_intra_nb_ctx` connected to real-intra stream_path consumer and first-MB-in-slice availability semantics. I acknowledged the seam and warned that final product reachability still needs the intra sub-engine under `h264_decode_core`, not only default-off `DECODE_REAL_INTRA=1` stream_path reach.

### W-DECODE / topology side

Contract I am building to:

- `h264_decode_core` is the product decoder target.
- `h264_decode_top` should become an intra-MB sub-engine inside that core.
- `decode_stub` is retired scaffolding and is no longer enough for deblock reachability claims.
- My deblock/writeback work is now structurally reachable from `h264_decode_core` via `u_core_deblock_wb`.
- I did not wire `stream_path` to `h264_decode_core`; W-DECODE owns that.

### W-CAST / syntax fields relevant to deblock

W-CAST asked what parser fields deblock/DPB seam expects. My answer/assumption set:

- QP per MB, and chroma QP must use QPc mapping for chroma thresholds/strength where applicable.
- Deblock strength depends on mb/sub_mb type, neighbour availability, coded-block/nonzero/TotalCoeff information, reference indices, and motion-vector deltas.
- Skipped MBs still participate in deblocking; they are not a writeback/deblock bypass. This is proven by skipped scope gates.

## 8. Open risks and anything I believe is wrong

- Biggest open risk: `h264_decode_core` is not yet proven reachable from the actual shipped `emu -> stream_path` product path in my branch. I proved deblock writeback reachable from root `h264_decode_core`; W-DECODE must wire that core into product. Until then, default `emu` reachability still mostly reflects old/default scaffolding.
- `h264_decode_core` currently instantiates the writeback controller and uses it as the commit/ref-ready ordering guard, but actual deblocking sample transformation inside core is not fully integrated as a real filter over reconstructed MBs. The full-frame seam proves all MBs flow through the writeback contract and are POST-deblock-side samples in the gate model; it does not prove final visual deblocking quality in a product-connected core RBF.
- Full-frame bS real-P gate currently scopes MB-boundary edges (`2271/2271`), not all internal 4x4 edges across the frame. Do not overclaim it.
- Tap-direction gate red-check is strong but small (`1/1170` MB, 4 PRE and 4 POST samples). Full-frame seam covers sample ordering, not every possible PRE/POST neighbour read.
- The real MB-golden deblock fixture QP `25..25` remains inside the QPc trap. The high-QP trap is synthetic by necessity. If a real high-QP fixture appears, add it.
- W-OSD's current `DECODE_REAL_INTRA=1` reachability evidence still describes a default-off branch that historically drops MC/DPB/deblock. It is useful for intra neighbour proof, but by itself it is not final product topology proof.
- Parent initially asked for `/tmp` handoff, but this environment forbids `/tmp` writes; parent corrected the path to `handoffs/` and this file is committed there.
