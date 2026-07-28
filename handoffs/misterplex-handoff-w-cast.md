# MiSTerPlex handoff — W-CAST

## 1. Identity

- Worker ID: W-CAST
- Branch: `w-cast-play-state`
- Worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-cast`
- Latest code commit SHA: `3c2d19126978b27d53029aae2f97e5fd47709ad0`
- Latest branch commit SHA: `aaba28f81ae7f5ac1df86f46fcaca3cce8f8e2e5`
- Handoff path: `handoffs/misterplex-handoff-w-cast.md`

## 2. Assignment

My current assignment was to own the H.264 Baseline/CAVLC parser side of the FPGA decode path and ensure it is product-reachable under the chosen decoder topology. Concretely: get CAVLC residual decode and parser metadata out of standalone/testbench-only code and under `h264_decode_core`, expose a consumer-safe handoff for W-DECODE/W-SWAP/W-DEBLOCK, and prove with reachability plus red/green gates that the signals are present in the product path.

Earlier in this workstream I also closed the Plex cast/user-visible bug where Plex Web stayed at 0:00 by fixing zero-offset progress release in the ARM companion. That is already committed and independently hardware-verified by parent; the current unfinished area is decode/CAVLC/parser handoff.

## 3. What is DONE and PROVEN

### Cast path defect closed

Done commits:
- `f801829 fix(companion): release zero-offset play progress`

Measured by parent after my fix:
- `playMedia` HTTP 200
- `/player/timeline/poll` returned `state="playing"` and time advanced: `4847 -> 11453 -> 17464 -> 23442` ms, about real-time 1.0x.

Important measurement lesson: client-facing `/player/timeline/poll` is the endpoint to assert for Plex Web, not PMS-side `/:/timeline` POSTs.

### Product CAVLC reachability and handoff under core

Done commits relevant to current assignment:
- `dffec7e fix(h264): parse real P-slice syntax`
- `72e75b6 fix(h264): emit all luma CAVLC residual blocks`
- `5771256 fix(h264): derive real intra4x4 modes`
- `da26559 fix(h264): require product CAVLC reachability`
- `a4f3ae6 fix(h264): expose CAVLC luma handoff`
- `3d4607e chore(h264): align CAVLC handoff names`
- `a4fd267 test(h264): prove high-nC CAVLC residuals`
- `ddaab84 fix(h264): anchor CAVLC handoff in decode core`
- `3c2d191 feat(h264): publish core macroblock syntax records`

Current product topology changes made by W-CAST:
- `stream_path.sv` now instantiates `h264_decode_core` as `product_decode_core`.
- Public `stream_path` CAVLC/i4 outputs are now driven by `h264_decode_core`, not by standalone parser-side instances:
  - `luma4x4_valid`
  - `luma4x4_idx[3:0]`
  - `luma4x4_qp[5:0]`
  - `luma4x4_total_coeff[4:0]`
  - `luma4x4_trailing_ones[1:0]`
  - `luma4x4_bit_offset_end[9:0]`
  - signed `luma4x4_coeff_zigzag[0:15]`
  - `luma4x4_source_busy/done/ok/source_bit_end`
  - `i4_modes[0:15]`
- `h264_decode_core.sv` now contains/exports:
  - 128-byte RBSP window input (`rbsp_byte[0:127]`) plus `rbsp_bit_len`.
  - In-core `h264_intra4x4_mode_deriver` instance `u_product_core_i4_mode_deriver`.
  - In-core `h264_luma4x4_residual_source #(.MAX_BYTES(128))` instance `u_product_core_luma4x4_residual_source`.
  - Existing P16 scheduled residual path still instantiates `h264_cavlc_residual_block`, now with `MAX_BYTES(128)`.
- `h264_decode_core` removed from `fpga/Plex_MiSTer/rtl/bench_only_modules.txt`.
- `scripts/check_rtl_module_instantiations.py` now requires topology edges:
  - `stream_path -> h264_decode_core`
  - `h264_decode_core -> h264_cavlc_residual_block`
  - `h264_decode_core -> h264_luma4x4_residual_source`
  - `h264_decode_core -> h264_intra4x4_mode_deriver`

Proof commands and raw results:

1. Product topology red/green:

Command (green):
```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-cast
python3 scripts/check_rtl_module_instantiations.py > build/wcast/module-inst_syntax_accept.log 2>&1; rc=$?; echo rc=$rc
```

Green result:
```text
Scope: all tracked fpga/Plex_MiSTer/rtl modules must be reachable from product root emu, unless explicitly bench-only; h264_decode_core is the product decoder and CAVLC/intra4x4 producers must sit under that core, not a standalone parser branch.
RTL_MODULE_INSTANTIATION_OK rtl_modules=70 reachable=48 bench_only=22 root=emu
rc=0
```

Red mutation: temporarily rename the `stream_path` instantiation from `h264_decode_core` to `h264_decode_core_missing`, then run the same script. It fails with:
```text
RTL_MODULE_INSTANTIATION_FAIL: required product modules are not reachable from emu: h264_cavlc_residual_block, h264_decode_core, h264_intra4x4_mode_deriver, h264_luma4x4_residual_source
MUTATION_RC=1
```

2. High-nC/high-TC CAVLC residual proof:

Command:
```bash
tests/unit/test_h264_cavlc_residual_verilator.sh > build/wcast/cavlc_after_core_attach.log 2>&1; rc=$?; echo rc=$rc
```

Green result:
```text
Scope: RTL CAVLC residual block plus luma4x4 source; 16/16 luma residual blocks for real IDR MB0 (1/300 MBs in 320x240 fixture) and synthetic table coverage
CAVLC_REAL_MB0_BLOCK11 high_nC_high_TC PASS: block=11 nC=7 table=2 total_coeff=12 trailing_ones=0 bit_start=489 bit_end=563 crosses_bit512=1
CAVLC_REAL_MB0_ALL16 PASS: blocks=16/16 final_bit_end=853 block11_bit_end=563 high_nC_block11_tc=12
Scope: luma4x4 source 16/16 luma residual blocks for real IDR MB0 (1/300 MBs in 320x240 fixture); coeff order=zigzag; qp=25
H264 CAVLC residual Verilator PASS: prefix-free tables checked; roundtrip_cases=527 including all coeff_token tables, luma/chroma total_zeros, run_before, nC edges, suffix escalation
rc=0
```

Red mutation in that gate:
- `CAVLC_NEGATIVE_TEST` perturbs coefficient decode and fails.
- `CAVLC_FAULT_BYTE_INDEX_WRAP` recreates the stale 64-byte/bit512 wrap class and fails on real MB0 block11.

Important measured detail: W-DECODE's previously reported block11 divergence (`expected end=563`, RTL ended `550`, final `763` vs `853`) is stale/refuted for current branch. The current RTL gets block11 end `563` and all-16 final end `853`. Scope is only real IDR MB0 luma blocks: 16/16 luma 4x4 blocks, which is 1/300 MBs in the 320x240 fixture, not a full 1170-MB 624x480 frame and not chroma.

3. Stream-path handoff and macroblock syntax records:

Command:
```bash
tests/unit/test_h264_multinal_stream_path.sh > build/wcast/h264_multinal_syntax_accept_redgreen.log 2>&1; rc=$?; echo rc=$rc
```

Green raw results:
```text
Scope: stream_path multi-NAL product RTL sim over one residual IDR+P fixture and one 12-frame P16 fixture; checks parsed residual/DPB/MC liveness, not HDMI output
multi-NAL stream_path raw: bytes=9060 bytes_in=9060 bytes_seen=9060 nalu=5 sps=1 pps=1 idr=1 slice=1 place_pulses=1 cavlc_luma_pulses=16 cavlc_luma_mask=0xffff cavlc_done=1 cavlc_bad_done=0 cavlc_nonzero_tc=14 cavlc_cbp_nonzero_seen=1 cavlc_qp=25 cavlc_cbp_luma_seen=0xf cavlc_cbp_chroma_seen=0x2 i4_modes_0_7_15=2/8/2 mb_syntax_records=2 mb_syntax_classes_i/p16/p16x8/p8x16=1/1/0/0 mb_syntax_unsupported=0 mb_syntax_bad_qp=0 mb_syntax_bad_cbp=0 ...
multi-NAL stream_path raw: bytes=27653 bytes_in=27653 bytes_seen=27652 nalu=15 sps=1 pps=1 idr=1 slice=11 place_pulses=1 cavlc_luma_pulses=16 cavlc_luma_mask=0xffff cavlc_done=1 cavlc_bad_done=0 cavlc_nonzero_tc=12 cavlc_cbp_nonzero_seen=1 cavlc_qp=27 cavlc_cbp_luma_seen=0xf cavlc_cbp_chroma_seen=0x2 i4_modes_0_7_15=2/8/2 mb_syntax_records=12 mb_syntax_classes_i/p16/p16x8/p8x16=1/8/2/1 mb_syntax_unsupported=0 mb_syntax_bad_qp=0 mb_syntax_bad_cbp=0 ... p_first_mb_seen=11 p_first_modes=8/2/1 p_first_bad=0 ...
rc=0
```

Red checks in that gate:
- implicit defaults refused (`rc=2`) if expected args omitted.
- forced recon signature zero is rejected.
- forced MB syntax unsupported (`FAULT_MB_SYNTAX_UNSUPPORTED=1`) is rejected with `decode_core MB syntax handoff flagged supported fixture unsupported`.
- deliberately wrong residual checksum is rejected.

Scope details: this stream gate covers one residual IDR+P fixture and one 12-frame P16 fixture. The 12-frame fixture reports first-MB syntax for 11 P slices, but it is not full-frame coverage and not the measured live 1170 MB/frame denominator.

4. h264_decode_core P16 real-P path still green after interface changes:

Command:
```bash
tests/unit/test_h264_decode_core_p16z_rtl_sim.sh > build/wcast/decode_core_p16z_syntax_accept.log 2>&1; rc=$?; echo rc=$rc
```

Green result:
```text
OK h264_decode_core p16x16 real-P scoreboard: 3 MBs syntax+MV-neighbor+CAVLC-residual path 384x3 exact clipped pred+16Y+8C scheduled-residual samples landed at DPB addresses; reads=63744 clipped_samples=56 clip_low=10 clip_high=46 rbsp_request_offsets=37/50/63 chroma_right_clamp_reads=96 cycles=131002 timeout_cycles=222704; nonterminal frame_done stayed low
rc=0
```

Red checks in that gate all still fire:
- dropped prediction
- dropped residual
- perturbed MV
- bad RBSP request
- dropped MV neighbor
- dropped scheduled residual
- dropped last luma residual
- dropped last chroma residual
- swapped scheduled coeff
- swapped chroma scheduled coeff
- swapped chroma read
- swapped chroma residual

5. Static/elab/build hygiene:

Commands:
```bash
make quartus-sv-subset > build/wcast/quartus-sv-subset_syntax_accept.log 2>&1; rc=$?; echo rc=$rc
make define-parity > build/wcast/define-parity_syntax_record_final.log 2>&1; rc=$?; echo rc=$rc
python3 tests/unit/test_bench_rtl_filelists.py > build/wcast/bench_rtl_filelists_syntax_record_final.log 2>&1; rc=$?; echo rc=$rc
```

Results:
```text
STATIC_PASS Quartus SV subset pattern scan: 34 file(s); toolchain=remote:docker; limitation=static_curated_patterns_only; paired_gate=verilator-elab_for_elaboration_errors; not_a_Quartus_analysis_or_synthesis_PASS
VERILATOR_ELAB_PASS: no owned RTL elaboration errors
PASS define parity: Quartus product macros match Verilator/lint; test-only macros are allowlisted
bench RTL file lists OK (31 RTL benches checked against 69 modules)
all rc=0
```

6. `make unit` status:

Command:
```bash
make unit > build/wcast/make-unit_syntax_accept.log 2>&1; rc=$?; echo rc=$rc
```

Result:
```text
rc=2
FAIL: SDC must not hide frame-store/DDR/arbiter timing with false or multicycle paths
```

This is the same pre-existing SDC invariant failure seen before these changes. In that full run, my owned/adjacent gates reached green before the SDC failure, including stream_path, h264_decode_core P16, define parity, and reachability. I did not override or suppress the SDC failure.

## 4. What is IN PROGRESS

Current git status was clean before this handoff and the latest code is committed/pushed. No half-edited RTL is intentionally left behind.

The current implementation is a first stable interface, not complete parser scheduling:
- `h264_decode_core` publishes one syntax record per `mb_type_valid` event it currently receives from `stream_path`/`slice_hdr_parser`.
- For current stream-path fixtures, that means one first-MB record per VCL slice, not all 1170 MBs/frame.
- Full P-skip expansion is not done in RTL. The interface has `mb_syntax_p_skip` and zero-CBP behavior, but `slice_hdr_parser` currently exposes first-MB / first-slice data and the tested fixtures did not report actual expanded P_Skip records.
- Ref/MVD arrays are placeholders/minimal: partition 0 is populated from the existing `mvd_x_qpel/mvd_y_qpel/ref_idx_l0` core inputs for non-skip P; remaining partitions are zero until parser emits per-partition MVD/sub_mb_type data.
- QPc is derived in-core via H.264 chroma QP mapping with `pps_chroma_qp_index_offset`, but `stream_path` currently passes `pps_chroma_qp_index_offset=0` because the old PPS parser does not expose chroma offset to stream_path yet.

Next concrete step for successor:
1. Extend the macroblock walker/parser feeding `h264_decode_core` so `mb_type_valid` occurs for every MB in raster/VCL order, including P_Skip expansion, not just first-MB per slice.
2. Parse and forward actual MVD/ref/sub_mb_type per partition/subpartition; reject nonzero `ref_idx_l0` for measured max_ref=1 instead of silently treating it as ref0.
3. Order residual-block pulses after the accepted syntax record for that same MB and before MB done/writeback scheduling.
4. Add a gate with a real 624x480 denominator (`1170` MBs/frame) once a full-frame MB syntax walk is product-wired.

## 5. What I TRIED THAT DID NOT WORK / refuted hypotheses

- Hypothesis: W-DECODE's reported high-nC CAVLC divergence might still be current. Refuted on current branch. Real MB0 block11 now decodes with nC=7/table2/TC=12, bit `489 -> 563`, and all-16 final bit end `853`. The likely old cause was the 64-byte RBSP index/bit512 wrap bug fixed earlier; the new `CAVLC_FAULT_BYTE_INDEX_WRAP` red check recreates that class.
- Bad topology: Having `h264_luma4x4_residual_source` and `h264_intra4x4_mode_deriver` directly under `stream_path` made them product-reachable but not under the chosen decoder core. Parent's ruling required them under `h264_decode_core`. I moved them into the core and made the reachability gate require exact edges, not just root reachability.
- `h264_decode_core` originally took a 64-byte RBSP window. That is insufficient for the real MB0 all-16 luma residual source crossing bit512. I widened it to 128 bytes and updated testbench filelists/wrappers.
- Using `type` as a SystemVerilog function argument name caused Verilator syntax errors (`unexpected type`). Renamed it to `mb_type_i`.
- Adding a new `stream_path` input (`mb_syntax_accept`) broke all wrappers until every product/test instantiation connected it. I connected top-level `Plex.sv` and stream_path testbench wrappers to `1'b1`. This is still a real ready/accept port for a future consumer; current top accepts immediately.
- Do not trust `make unit` as green here; it still fails on a pre-existing SDC invariant. Targeted gates are the evidence for my changes.

## 6. Gates W-CAST owns / modified

### `scripts/check_rtl_module_instantiations.py`

Run:
```bash
python3 scripts/check_rtl_module_instantiations.py
```

Green state:
```text
Scope: all tracked fpga/Plex_MiSTer/rtl modules must be reachable from product root emu, unless explicitly bench-only; h264_decode_core is the product decoder and CAVLC/intra4x4 producers must sit under that core, not a standalone parser branch.
RTL_MODULE_INSTANTIATION_OK rtl_modules=70 reachable=48 bench_only=22 root=emu
```

What it literally compares:
- Source-level module instantiation graph from product root `emu`.
- All tracked RTL modules must be reachable or listed bench-only.
- Required modules must be reachable.
- Required topology edges must exist from `stream_path` to `h264_decode_core`, and from `h264_decode_core` to the CAVLC/i4 producers.

What it does not cover:
- It does not prove synthesis did not optimize logic away after elaboration.
- It does not prove functional correctness.
- It does not prove `h264_decode_core` has replaced `decode_stub` as the frame producer yet; stub remains instantiated for diagnostic present behavior.

How to make it fail:
- Rename `h264_decode_core` instantiation in `stream_path.sv` to a nonexistent module. It fails with required product modules unreachable.
- Remove `h264_luma4x4_residual_source` from `h264_decode_core`; it fails required edge/topology.

### `tests/unit/test_h264_cavlc_residual_verilator.sh`

Run:
```bash
tests/unit/test_h264_cavlc_residual_verilator.sh
```

Green state:
- Checks synthetic CAVLC tables and real IDR MB0 all-16 luma residual blocks.
- Raw key values: block11 nC=7/table2/TC=12/T1=0, bit `489 -> 563`, crosses bit512; all16 final bit end `853`.

What it does not cover:
- Not full-frame 1170 MB coverage.
- Not chroma DC/AC handoff through stream_path/core.
- Not product scheduling into MC/deblock/writeback.

How to make it fail:
- `CAVLC_NEGATIVE_TEST` causes coefficient mismatches.
- `CAVLC_FAULT_BYTE_INDEX_WRAP` makes the old byte-index wrap class fail on real block11.

### `tests/unit/test_h264_multinal_stream_path.sh`

Run:
```bash
tests/unit/test_h264_multinal_stream_path.sh
```

Green state:
- First fixture: 2 MB syntax records (`I_NxN=1`, `P16=1`), 16 luma pulses, mask `0xffff`, QP=25, i4 modes `2/8/2` sampled.
- 12-frame P fixture: 12 MB syntax records (`I_NxN/P16/P16x8/P8x16 = 1/8/2/1`), 16 luma pulses, mask `0xffff`, QP=27, unsupported=0, bad_qp=0, bad_cbp=0.

What it does not cover:
- Not HDMI output.
- Not full 1170 MB/frame parsing.
- Does not prove P_Skip expansion because current fixture/stream_path first-MB path does not produce expanded skip records.

How to make it fail:
- Run with no expected args: implicit-default refusal rc=2.
- `FAULT_RECON_SIG_ZERO=1` build rejects missing P DPB/MC recon liveness.
- `FAULT_MB_SYNTAX_UNSUPPORTED=1` build rejects a supported fixture flagged unsupported.
- Wrong expected residual checksum (`0xff`) fails.

### `tests/unit/test_h264_decode_core_p16z_rtl_sim.sh`

Run:
```bash
tests/unit/test_h264_decode_core_p16z_rtl_sim.sh
```

Green state:
- `3 MBs syntax+MV-neighbor+CAVLC-residual path 384x3 exact clipped pred+16Y+8C scheduled-residual samples landed at DPB addresses`.

What it does not cover:
- Does not cover full P8x8/subpartition parser handoff.
- Does not cover full product stream_path replacement of `decode_stub`.

How to make it fail:
- Built-in expected-red defines cover dropped pred/residual, perturbed MV, bad RBSP req, dropped MV neighbor, dropped scheduled residual, dropped last luma/chroma residual, swapped scheduled/chroma coeffs, swapped chroma read/residual.

### Supporting gates

- `make quartus-sv-subset` currently rc=0 for my changes; static subset + Verilator elab only, not Quartus fit/RBF.
- `make define-parity` currently rc=0; confirms added test-only macros are allowlisted and product macros match.
- `python3 tests/unit/test_bench_rtl_filelists.py` currently rc=0; confirms benches include RTL dependencies.
- `make unit` currently rc=2 due to pre-existing SDC invariant failure; do not report it green.

## 7. Interfaces agreed with other workers

### W-DECODE handoff

Producer boundary (now under `h264_decode_core`, exported through `stream_path` for compatibility):
- `luma4x4_valid`: one pulse per 4x4 luma block.
- `luma4x4_idx[3:0]`: block index 0..15.
- `luma4x4_coeff_zigzag[0:15]`: signed 16-bit coefficients in H.264 zigzag/scan order, not raster/dequant order.
- `luma4x4_qp[5:0]`.
- Optional/available: `luma4x4_total_coeff`, `luma4x4_trailing_ones`, `luma4x4_bit_offset_end`, source busy/done/ok/end.
- `i4_modes[0:15]`: derived intra4x4 modes stable before/through luma pulses for the current I_NxN MB.

Consumer-side requirement from W-DECODE:
- Do not silently zero missing blocks under PASS.
- Count received blocks; fail unless all 16 expected luma blocks arrive for an I_NxN MB.
- `h264_decode_top` should be an intra-MB sub-engine inside `h264_decode_core`, not a stream_path replacement branch.

### W-SWAP / MC handoff

Agreed/implemented first-step interface from `h264_decode_core`:
- `mb_syntax_accept` input: consumer accept/ready. Current top/test wrappers tie it high; future MC can backpressure.
- `mb_syntax_valid` output: held until accepted.
- Address/position: `mb_syntax_addr`, `mb_syntax_x`, `mb_syntax_y`.
- Class/type: `mb_syntax_class`, `mb_syntax_type`, `mb_syntax_p_skip`, `mb_syntax_part_mode`, `mb_syntax_part_count`, `mb_syntax_uses_sub_mb`, `mb_syntax_unsupported`.
- Ref/MVD placeholders/arrays: `mb_syntax_ref_idx_l0[0:3]`, signed `mb_syntax_mvd_x_qpel[0:3]`, signed `mb_syntax_mvd_y_qpel[0:3]`, `mb_syntax_sub_mb_type[0:3]`.
- Residual/QP/CBP: `mb_syntax_cbp_luma`, `mb_syntax_cbp_chroma`, `mb_syntax_mb_qp_delta`, `mb_syntax_qpy`, `mb_syntax_qpc`, `mb_syntax_residual_bit_offset`.

Timing contract:
- Syntax record should be emitted only after all fields for that MB are parsed.
- Fields must remain stable while `valid=1` until `accept=1`.
- Residual stream for a MB must be ordered after its syntax header and before MB-done/writeback scheduling.
- P_Skip must eventually expand to one MB record per skipped MB, zero CBP, `p_skip=1`, no residual/MVD.
- For live max_ref=1, nonzero `ref_idx_l0` should raise unsupported/error, not silently feed MC.
- MC can derive final MV from MVD + neighbor state if records arrive in raster order; if parser later emits final MV too, keep MVD exposed so MV predictor bugs are catchable.

Current caveat: the committed interface is only a first-step record publisher. It does not yet parse all MVD/sub_mb_type arrays or expand skip_run across all MBs.

### W-DEBLOCK handoff

W-DEBLOCK requested syntax/recon metadata:
- QPy per MB after `mb_qp_delta` accumulation.
- QPc via H.264 chroma QP table and PPS/slice chroma offsets; do not silently use QPy for chroma.
- `disable_deblocking_filter_idc`, `slice_alpha_c0_offset_div2`, `slice_beta_offset_div2`.
- MB/block type metadata, intra/inter classification, partition shape.
- Neighbor availability.
- Nonzero residual flags / TotalCoeff per luma and chroma block.
- Ref/MV metadata for bS=1 decisions.

Current W-CAST-provided pieces:
- `mb_syntax_qpy`, `mb_syntax_qpc`, `mb_syntax_cbp_luma/chroma`, class/partition, ref/MVD placeholders.
- Baseline syntax gate previously measured live-like 624x480 P-frame parser coverage: `1170/1170` MBs, `QPy_range=3..33`, `luma4x4_nonzero=726/18720`, `chroma_dc_nonzero=210/2340`, `chroma_ac4x4_nonzero=513/9360`, `mvd_pairs=197`, neighbor edges counted. That was parser gate evidence, not product stream_path/core full-frame scheduling evidence.

## 8. Open risks / things I believe are wrong

- `decode_stub` is still instantiated and still drives diagnostic frame output in `stream_path`. My CAVLC/syntax work is under `h264_decode_core`, but the product present path is not yet fully switched to core output. This is expected under the architecture ruling but is not complete decode-off-ARM.
- `mb_syntax_valid` currently accepts immediately in top-level and test wrappers. The port exists for W-SWAP, but no real consumer currently backpressures it.
- Full raster/VCL macroblock scheduling is missing from product stream_path/core. Existing product signals are first-MB-per-slice oriented, so any claim over a full 1170 MB frame would be false unless using the separate syntax parser gate.
- P_Skip expansion is explicitly not complete in product RTL. The user/parent/W-SWAP requested one record per skipped MB; current code does not yet do that in stream_path/core.
- Actual per-partition MVD/ref/sub_mb_type arrays are not parsed into the core record yet. Nonzero ref detection exists only against the current scalar `ref_idx_l0` input.
- QPc mapping exists in `h264_decode_core`, but `stream_path` passes PPS chroma offset as zero. Need to expose PPS chroma QP offset from the parser before W-DEBLOCK can rely on high-QP chroma behavior in product.
- `make unit` failing SDC invariant may block integration even though targeted RTL gates are green. I did not fix it because it is outside my task and pre-existing.
- Parent corrected the handoff location after the first attempt; the durable handoff is committed at `handoffs/misterplex-handoff-w-cast.md`.
