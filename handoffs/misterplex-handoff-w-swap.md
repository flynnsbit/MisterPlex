# W-SWAP handoff

## 1. Identity

- Worker ID: W-SWAP
- Branch: `w-swap-mc`
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-swap-mc`
- Latest commit: `5fd697dc494c5f1570957f1e3b4f96e4c264dab5` (handoff commit; latest RTL work commit before handoff was `910c4561df59e500d50161919344fc7a185b44b7` / `Route decode-core P16 through block MC`)
- Handoff path: `handoffs/misterplex-handoff-w-swap.md`
- Push status: to be pushed twice after committing this handoff; `git status -sb` clean at handoff time after push.

## 2. Assignment

Originally I owned the DDR frame-store swap livelock fix and its natural red/green gate. After that landed, I was reassigned to P-slice inter prediction / motion compensation, specifically making MC land under the agreed unified decoder topology rather than remaining a module-green/product-absent subsystem. My current work targets the staged `h264_decode_core` P16 path and routes it through the product block MC primitive (`h264_inter_mc_part`) while preserving the deblock/DPB seam contract.

## 3. What is DONE and PROVEN

### DDR frame-store swap livelock (done before current branch)

- Fixed prep allocator in `fpga/Plex_MiSTer/rtl/ddr_frame_store.sv` to evict stale valid prep slots using literal prep keep-set lines (`0..LINE_COUNT-1`, chroma `tk>>1`) instead of only invalid slots.
- Natural Verilator gate was added and registered in unit: cold reset -> doorbells 0,1,0 -> assert third swap, with no hierarchical injection/forcing of `y_valid`/`y_bank`/`y_line`.
- Parent independently verified patched GREEN and unpatched RED; merged as parent commit `208f71c`.

### MC/inter gates strengthened (committed before topology pivot)

These changes were already pushed on `w-swap-mc` before the latest commit:

- `tests/unit/test_p3_inter_rtl_sim.sh` prints `Scope:` first.
- `tests/rtl/h264_inter_pred_tb.cpp` added:
  - luma qpel stress: `16+128`
  - chroma epel stress: `3+1024`
  - full-frame fetch/clamp sweep: `fetch=5+3510`, `frame_mv_mbs=3510/1170`
- `tests/unit/test_p3_dpb_mc_rtl_sim.sh` prints `Scope:` first and explicitly states MC reads post-deblock committed DPB.
- `tests/rtl/h264_dpb_mc_tb.cpp` prints `tap=post-deblock-committed-DPB`, `mc_mb_fraction=1/1170`, `fetch_mb_fraction=2/1170`.

Measured current green commands:

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-swap-mc
bash tests/unit/test_p3_inter_rtl_sim.sh > build/w-swap-logs/p3_inter.log 2>&1; rc=$?
# rc=0
```

Raw green line:

```text
Scope: h264_inter_pred product RTL primitives only; no hierarchical RTL pokes; covers Baseline single-ref P MV prediction, P_Skip, luma qpel, chroma epel, clamp/fetch address math; not full-frame decode/reconstruction; QPc not covered (prediction-only, no QP).
OK real RTL sim: h264_inter_pred product RTL mv_cases=6 partition_cases=10 frame_mv_cases=9090 frame_mv_mbs=3510/1170 frame_modes=690/720/720/690/690 luma_qpel=16+128 chroma_epel=3+1024 clamp=3 fetch=5+3510 fixture=tests/fixtures/p3_inter_pred/inter_mc_v1.json
OK h264_inter_pred RTL red-check: bad rounding fault failed golden
OK h264_inter_pred RTL red-check: bad partition MV fault failed golden
```

```bash
bash tests/unit/test_p3_dpb_mc_rtl_sim.sh > build/w-swap-logs/dpb_mc.log 2>&1; rc=$?
# rc=0
```

Raw green line:

```text
Scope: h264_dpb_one_ref + h264_inter_mc_part product RTL; MC reads post-deblock committed DPB reference samples via filtered writeback/deblock seam; covers 624x480 one-ref fetch/clamp/MC arithmetic and seam ordering, not full-frame H.264 residual/recon quality; QPc not covered.
OK real RTL sim: h264_dpb_mc product RTL nals=15 tap=post-deblock-committed-DPB i420_writes=1536 luma_window=441 chroma_windows=81/81 mc_pixels=256/64/64 mc_mb_fraction=1/1170 fetch_mb_fraction=2/1170 part_modes=16x8/8x16/8x8/8x4/4x8/4x4 fixture=tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264
OK h264_dpb_mc deblock-DPB seam: filtered samples precede wb_valid; terminal wb_valid precedes frame_done/ref_ready; MC reference tap is post-deblock committed DPB nals=15 fixture=tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264
OK h264_dpb_mc RTL red-check: deblock early MB commit fault failed seam
OK h264_dpb_mc RTL red-check: deblock early frame_done fault failed seam
OK h264_dpb_mc RTL red-check: bad edge clamp fault failed golden
OK h264_dpb_mc RTL red-check: bad MC arithmetic fault failed golden
OK h264_dpb_mc RTL red-check: early reference publication fault failed golden
OK h264_dpb_mc RTL red-check: bad partition mask fault failed golden
```

### Latest commit: decode-core P16 now consumes block MC

Commit `910c4561df59e500d50161919344fc7a185b44b7` changed the staged `h264_decode_core` P16 path:

- Replaced private per-sample qpel/epel prediction with an instance of `h264_inter_mc_part`.
- P16 reference fetch now loads full windows once per MB:
  - luma: `21*21 = 441`
  - chroma U: `9*9 = 81`
  - chroma V: `9*9 = 81`
  - total: `603` DPB reads/MB instead of old `21248` per-sample reads/MB.
- Updated scoreboards and expected-red read ordinals to the new full-window ordering.
- Added `Scope:` first lines to decode-core gates.
- Updated docs: `docs/phase3-inter-rtl.md`, `docs/PHASE_BACKLOG.md`.

Measured commands and raw numbers:

```bash
bash tests/unit/test_h264_decode_core_p16z_rtl_sim.sh > build/w-swap-logs/p16z_after_scope.log 2>&1; rc=$?
# rc=0
```

Raw green/red evidence:

```text
Scope: h264_decode_core staging P16 path; no hierarchical RTL pokes; covers 3/1170 MBs with syntax handoff, MV-neighbour prediction, CAVLC residual scheduling, h264_inter_mc_part full-window MC, and DPB writeback; not full-frame product reachability.
OK h264_decode_core p16x16 real-P scoreboard: 3 MBs syntax+MV-neighbor+CAVLC-residual path 384x3 exact clipped pred+16Y+8C scheduled-residual samples landed at DPB addresses; reads=1809 clipped_samples=56 clip_low=10 clip_high=46 rbsp_request_offsets=37/50/63 chroma_right_clamp_reads=36 cycles=7132 timeout_cycles=222704; nonterminal frame_done stayed low
OK h264_decode_core p16x16 real-P red-check: dropped prediction fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: dropped residual fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: perturbed MV fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: bad RBSP request fault failed syntax scoreboard
OK h264_decode_core p16x16 real-P red-check: dropped MV neighbor fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: dropped scheduled residual fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: dropped last luma residual fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: dropped last chroma residual fault failed exact samples
OK h264_decode_core p16x16 real-P red-check: swapped scheduled coefficient fault failed scan-order scoreboard
OK h264_decode_core p16x16 real-P red-check: swapped chroma coefficient fault failed scan-order scoreboard
OK h264_decode_core p16x16 real-P red-check: swapped chroma read fault failed U/V scoreboard
OK h264_decode_core p16x16 real-P red-check: swapped chroma residual fault failed U/V residual scoreboard
```

```bash
bash tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh > build/w-swap-logs/real_slice_after_scope.log 2>&1; rc=$?
# rc=0
```

Raw evidence:

```text
Scope: h264_decode_core staging P16 path on real disabled-loop-filter I420 content; no hierarchical RTL pokes; covers 2/1170 MBs with h264_inter_mc_part full-window MC and U/V plane distinctness; not full-frame product reachability.
test_h264_decode_core_real_slice: OK real-content disabled-loop-filter I420 slice reconstructed 2 P16 MBs exact; residual_nonzero=768 uv_distinct_samples=128 chroma_right_clamp_reads=18 varied-real-content=0->1@(5,0) right-edge-chroma-clamp=0->1@(38,7)
OK h264_decode_core real-slice red-check: swapped U/V chroma read failed real-content scoreboard
```

```bash
bash tests/unit/test_h264_decode_core_writeback_rtl_sim.sh > build/w-swap-logs/writeback_after_scope.log 2>&1; rc=$?
# rc=0
```

Raw evidence:

```text
Scope: h264_decode_core staging native-I420 writeback path; no hierarchical RTL pokes; covers 2/1170 MBs and terminal frame_done; not MC arithmetic, parser correctness, or product reachability.
OK h264_decode_core writeback scoreboard: 2 MBs, 768 native-I420 samples landed at DPB addresses; terminal frame_done observed
OK h264_decode_core writeback red-check: dropped writeback fault failed scoreboard
```

### Product-reachability and full unit state

```bash
python3 scripts/check_rtl_module_instantiations.py > build/w-swap-logs/reachability.log 2>&1; rc=$?
# rc=0
```

Raw output:

```text
RTL_MODULE_INSTANTIATION_OK rtl_modules=68 reachable=44 bench_only=24 root=emu
```

Important: this only says every RTL module is either product-reachable or explicitly bench-only. It does NOT prove `h264_decode_core` is product-reachable; it is still staging/bench-only until W-DECODE wires it under `stream_path`.

Final full unit:

```bash
make unit > build/w-swap-logs/make_unit_final.log 2>&1; rc=$?
# rc=0
```

Raw tail summary includes:

```text
GATE_SKIP_SUMMARY total=2 critical=1 high=1 advisory=0
GATE_SKIP CRITICAL live-pms-baseline-profile: ... set PLEX_BASE, PLEX_TOKEN, and MISTERPLEX_BASELINE_KEY ...
GATE_SKIP HIGH skip-not-pass: reason=OK red-check: live PMS wrapper missing deps return SKIP-NOT-PASS rc=77
```

Assumption vs measurement:

- Measured: all commands above rc=0; all raw numbers above are from logs.
- Measured by W-GATE, accepted by me: `h264_decode_core` is still bench-only, and strict completeness says it currently does not instantiate `h264_dpb_one_ref`.
- Assumed/target only: `h264_decode_core` is the intended product decoder topology after W-DECODE wiring. My commit does not itself wire it into `stream_path`.

## 4. What is IN PROGRESS

Nothing is half-edited. Worktree is clean.

Current stopping point:

- The staged `h264_decode_core` P16 path now uses `h264_inter_mc_part`, but the core is not product-instantiated.
- No files are touched/uncommitted.
- Next concrete step is for W-DECODE (or successor if reassigned) to wire `h264_decode_core` under `stream_path` and then re-run W-GATE's decoder completeness/lineage gate. After that, W-SWAP successor should re-check whether `h264_inter_mc_part` is in the product-reachable set under root `emu`, not merely green in the decode-core testbench.

## 5. What I TRIED THAT DID NOT WORK

- Treating `h264_decode_top` as the product decode replacement is wrong. W-GATE measured `DECODE_REAL_INTRA=1` root=`h264_decode_top` drops inter/MV/DPB/deblock/writeback. It is intra-only and cannot decode the measured live stream (mostly P-slices). Do not build MC under that as a top-level product replacement.
- The old `h264_decode_core` P16 path used private per-sample `h264_luma_qpel_sample` / `h264_chroma_epel_sample` style fetches. Tests could be made green, but that did not prove the product block MC primitive (`h264_inter_mc_part`) was exercised. I replaced it with full-window block MC to avoid another module-green/product-absent subsystem.
- I initially described `h264_decode_core` as if it owned/instantiated `h264_dpb_one_ref`. W-GATE measured that was false. `h264_dpb_one_ref` parsed parents are `decode_stub` and `h264_decode_skeleton`; `h264_decode_core.sv` mentions DPB but currently exposes DPB read/write ports and does not instantiate `h264_dpb_one_ref`. Measurement wins. Any completeness gate should continue to flag DPB/reference-store missing from the core until product wiring decides whether the core or an outer wrapper owns it.
- After adding Scope lines, I briefly broke `test_h264_decode_core_writeback_rtl_sim.sh` by replacing the `RUN_VERILATOR=...` line with the Scope echo. The failure was `RUN_VERILATOR: unbound variable`; fixed by restoring `RUN_VERILATOR` before the echo. This is fixed in commit `910c456`.
- One `make unit` rerun failed once at `build/test_companion_eof` with `FAIL: path callback key mismatch: /library/metadata/3`. I re-ran `build/test_companion_eof` standalone and it passed (`rc=0`), then re-ran full `make unit` and it passed (`rc=0`). I did not change companion code. Treat this as a transient or unrelated order/state issue, not an MC finding.
- A previous invalid style of frame-store gate (not mine in final form) poisoned/injected stale prep state. That only proves non-recovery from a stale state. The landed frame-store gate reaches the livelock naturally from reset and three doorbells; keep that distinction.

## 6. Gates I own

### `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh`

Run:

```bash
bash tests/unit/test_h264_decode_core_p16z_rtl_sim.sh
```

Current state: GREEN rc=0. Covers `3/1170` MBs. Literal comparisons: DPB read addresses, DPB write addresses/data, clipped prediction+residual samples, RBSP request offsets, frame_done nonterminal behavior. Does not cover full-frame traversal, product reachability, all P modes, QPc, or real deblocked references.

How to make it fail: the script builds expected-red mutants and checks `tests/expected_red_manifest.json`. Fault defines include:

- `H264_DECODE_CORE_FAULT_DROP_PRED`
- `H264_DECODE_CORE_FAULT_DROP_RESIDUAL`
- `H264_DECODE_CORE_FAULT_PERTURB_MV`
- `H264_DECODE_CORE_FAULT_BAD_RBSP_REQ`
- `H264_DECODE_CORE_FAULT_DROP_MV_NEIGHBOR`
- `H264_DECODE_CORE_FAULT_DROP_SCHEDULED_RESIDUAL`
- `H264_DECODE_CORE_FAULT_DROP_LAST_LUMA_RESIDUAL`
- `H264_DECODE_CORE_FAULT_DROP_LAST_CHROMA_RESIDUAL`
- `H264_DECODE_CORE_FAULT_SWAP_SCHEDULED_COEFF`
- `H264_DECODE_CORE_FAULT_SWAP_CHROMA_COEFF`
- `H264_DECODE_CORE_FAULT_SWAP_CHROMA_READ`
- `H264_DECODE_CORE_FAULT_SWAP_CHROMA_RESIDUAL`

Example current expected-red ordinals after the 603-read/MB conversion:

- perturb MV: `read_ordinal 0 got_addr=0x400f want_addr=0x400e`
- drop MV neighbor: `read_ordinal 603 got_addr=0x401e want_addr=0x401f`
- swap chroma read: `read_ordinal 441 got_addr=0x4a08 want_addr=0x4808`

### `tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh`

Run:

```bash
bash tests/unit/test_h264_decode_core_real_slice_rtl_sim.sh
```

Current state: GREEN rc=0. Covers `2/1170` MBs on real disabled-loop-filter I420 content. Literal comparisons: DPB read addresses, DPB write addresses/data, U/V plane distinctness, right-edge chroma clamp reads. Does not cover full frame, true parser traversal, deblocked reference generation, product reachability, or QPc.

How to make it fail: script builds `+define+H264_DECODE_CORE_FAULT_SWAP_CHROMA_READ`. Expected-red substring currently:

```text
FAIL h264_decode_core real-slice scoreboard: varied-real-content slice=0->1 mb=(5,0) read_ordinal 441 got_addr=0x5f6a8 want_addr=0x4d228
```

### `tests/unit/test_h264_decode_core_writeback_rtl_sim.sh`

Run:

```bash
bash tests/unit/test_h264_decode_core_writeback_rtl_sim.sh
```

Current state: GREEN rc=0. Covers `2/1170` MBs and terminal `frame_done` for native-I420 writeback. Does not cover MC arithmetic, parser correctness, or product reachability.

How to make it fail: script builds `+define+H264_DECODE_CORE_FAULT_DROP_WB`; red-check requires nonzero rc and a `write count` diagnostic.

### `tests/unit/test_p3_inter_rtl_sim.sh`

Run:

```bash
bash tests/unit/test_p3_inter_rtl_sim.sh
```

Current state: GREEN rc=0. Covers product RTL primitives for single-ref P prediction, not integrated decode. Red-checks:

- bad interpolation rounding fault
- bad partition MV fault

### `tests/unit/test_p3_dpb_mc_rtl_sim.sh`

Run:

```bash
bash tests/unit/test_p3_dpb_mc_rtl_sim.sh
```

Current state: GREEN rc=0. Covers `h264_dpb_one_ref + h264_inter_mc_part` product RTL and the post-deblock committed DPB seam. Denominators printed: `mc_mb_fraction=1/1170`, `fetch_mb_fraction=2/1170`.

How to make it fail: built-in red checks for:

- early deblock MB commit
- early frame_done/ref_ready
- bad edge clamp
- bad MC arithmetic
- early reference publication
- bad partition mask

### `scripts/check_rtl_module_instantiations.py`

Run:

```bash
python3 scripts/check_rtl_module_instantiations.py
```

Current state: GREEN rc=0 with `rtl_modules=68 reachable=44 bench_only=24 root=emu` on my branch. This is an inventory/bench-only gate only; W-GATE's stricter completeness/lineage gate is the one that should fail the current split topology.

### `make unit`

Run:

```bash
make unit
```

Current state: GREEN rc=0 on final rerun. It still emits two skip summaries for missing live PMS credentials; those are rc=77 skips summarized by the harness, not MC failures.

## 7. Interfaces agreed with other workers

### Topology with W-DECODE / W-GATE

- Binding target: `h264_decode_core` is the single product decoder target.
- `h264_decode_top` should be an intra-MB sub-engine inside that core, not a `stream_path` top-level replacement.
- `decode_stub` is scaffold/fallback to retire, not final product.
- W-SWAP's current claim is narrow: MC block arithmetic (`h264_inter_mc_part`) is now used inside staged `h264_decode_core` P16. I do NOT claim the core is product-reachable or product-complete yet.
- W-GATE measured four lineages and corrected me: `h264_decode_core` does not instantiate `h264_dpb_one_ref`; DPB/reference-store completeness remains missing for the core until product wiring resolves ownership.

### Deblock/DPB seam with W-DEBLOCK

- MC/reference fetch consumes only the committed POST-deblock DPB reference plane.
- MC must not tap PRE-deblock local recon / intra-neighbour context.
- Intra/local neighbour context consumes PRE-deblock reconstruction only.
- W-DEBLOCK tap names in their gate:
  - PRE-deblock neighbour context: `filtered_sample_pre_tap` / `tap_pre_recon`
  - POST-deblock DPB write input: `filtered_sample`
- W-DEBLOCK's seam fix delays the deblock terminal/ref-ready pulse one cycle into DPB `frame_done`; `ref_ready` must not be same-phase with terminal deblock commit.
- My `test_p3_dpb_mc_rtl_sim.sh` Scope and evidence line explicitly state `tap=post-deblock-committed-DPB`.
- W-DEBLOCK later reported their full-frame seam gate now drives `1170/1170` real 624x480 P-frame MBs through deblock writeback into DPB, including `928/928` skipped MBs (`356352` skipped samples, `449280` total samples). Their red-check `--fault-skip-bypass` proves skipped MBs cannot bypass filtered writeback. They measured `h264_deblock_writeback_ctrl` product-reachable in the current default topology `emu -> stream_path -> decode_stub`, red-proved by mutating the `decode_stub` instantiation. If topology moves to `h264_decode_core`, the same writeback controller must be product-reachable there before MC consumes refs.

### Parser/residual handoff with W-CAST/W-DECODE

- W-DECODE asked W-CAST to provide per-block luma coeffs in zigzag/scan order, e.g. `luma4x4_coeff_zigzag[0:15]`, with `luma4x4_valid`, `luma4x4_idx[3:0]`, signed coeffs, QP, and i4 modes stable before/through residual pulses.
- My decode-core P16 gate currently uses the core's existing P16 syntax/MV/residual hooks and RBSP request path. It proves request offsets `37/50/63` in the synthetic P16 cases but does not prove W-CAST's full parser is product-connected.
- For MC, I expect P MB metadata under the chosen core: MB address, P16/P partitions, ref_idx_l0, mvd/mv, cbp/QP/residual availability. I did not design a new parser interface.

## 8. Open risks and anything I believe is wrong

- Biggest unfinished item: `h264_decode_core` is still bench-only/not wired under `stream_path`. Until that changes and W-GATE's completeness gate proves the intended modules product-reachable, W-SWAP's MC work can still be product-absent.
- W-GATE's raw results should be treated as authoritative: current product `DECODE_REAL_INTRA=0` root=`decode_stub` has inter/MV/DPB but misses bitstream entropy, residual/dequant/transform, intra prediction, deblocking/writeback categories; current product `DECODE_REAL_INTRA=1` root=`h264_decode_top` drops inter/MV/DPB/deblock/writeback. Neither product branch is a complete decoder.
- `h264_decode_core` strict completeness is not solved by my commit. It now uses block MC arithmetic, but DPB/reference-store ownership, product parser/entropy, full residual/dequant/transform category scoring, and deblock/writeback integration remain incomplete or externally owned.
- The decode-core gates are narrow by design: `3/1170` synthetic P16 MBs, `2/1170` real-content P16 MBs, `2/1170` writeback MBs. They are good local gates but not full-frame quality gates.
- No Quartus fit was run. Full-window combinational `h264_inter_mc_part` inside `h264_decode_core` may have resource/timing implications. W-FIT owns the sole fit slot.
- Prediction-only gates do not cover QPc. Docs say this explicitly; do not infer chroma QP correctness from MC green.
- The final `make unit` green still has live PMS skips due missing credentials. That is baseline repository behavior, not a W-SWAP MC proof.
- Handoff is committed in-repo at `handoffs/misterplex-handoff-w-swap.md` per corrected parent instruction.
