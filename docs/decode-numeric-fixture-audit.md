# Decode numeric fixture mutation audit

Pre-registered prediction before the audit: **SOUND=6, VACUOUS=2, OVER-TIGHT=1** among sampled high-risk decode numeric fixtures.

Observed result after the first pass: **SOUND=7, VACUOUS=2 (both closed here), OVER-TIGHT=0**. The over-tight prediction did not reproduce in numeric fixtures; the source-shape over-tightness remains in source-text invariants, not in these sampled numeric comparisons.

## Findings

| Area | Property | Mutation | Evidence | Verdict |
| --- | --- | --- | --- | --- |
| DPB/MC | U distinguished from V | `i420_addr` V phase reads plane `2'd1` instead of `2'd2` | `FAIL h264_dpb_mc RTL: chroma window clamp mismatch plane=2 idx=0 got=83 want=191` | Sound |
| DPB/MC | Luma distinguished from chroma | `i420_addr` U phase reads plane `2'd0` instead of `2'd1` | `FAIL h264_dpb_mc RTL: chroma window clamp mismatch plane=1 idx=0 got=17 want=83` | Sound |
| DPB/MC | Lower clamp boundary | Existing bad-clamp red probe | `FAIL h264_dpb_mc RTL: luma window clamp mismatch idx=0 got=18 want=17 src=(0,0)` | Sound |
| DPB/MC | Upper clamp boundary | `clamp_coord` high side returns `limit - 2` instead of `limit - 1` | Before edge sentinels: green. After edge sentinels: `FAIL h264_dpb_mc RTL: upper luma window clamp mismatch idx=202 got=59 want=68 src=(623,476)` | Was vacuous; closed |
| Chroma plane | H/V gradients, chroma constant, offset, clipping | Existing chroma red probes mutate constant, offset, clipping, and H/V | `ALL 4 mutation probes detected — RED proofs complete.` | Sound |
| IDCT/dequant | Coefficient magnitude | Dequant multiplier `* 16` changed to `* 8` | `FAIL real RTL sim: block=0 dequant[0] got -2112 want -4224` | Sound |
| IDCT/dequant | Coefficient position / scan placement | Swap dequant outputs for positions 1 and 4 | `FAIL real RTL sim: block=1 dequant[1] got -224 want 0` | Sound |
| IDCT/recon | Reconstructed-pixel clipping | `clip8` returns `v[7:0]` without saturation | Before clip probe: green. After clip probe: `FAIL real RTL sim: recon clip boundary upper got 247 want 255` | Was vacuous; closed |

## Extended sweep

| Area | Property | Mutation | Evidence | Verdict |
| --- | --- | --- | --- | --- |
| IDCT/dequant | Scan-order placement across dequant matrix classes | `zigzag` swaps scan 1 and scan 4 (`pos 1` class 1 ↔ `pos 5` class 2) | `FAIL real RTL sim: scan placement dequant[1] got 2016 want 1568` | Sound |
| IDCT reference fixture | AC coefficient sign/magnitude | `MPLEX_P3_IDCT_REF_PERTURB=dequant_ac` | `FAIL dequant[1]: got=-896 want=896` | Sound |
| IDCT reference fixture | Frame MAE rows are per-MB, not a summary-only checksum | `MPLEX_P3_IDCT_REF_PERTURB=frame_mae` | `FAIL frame_mae mb=17: got sum=1 pixels=256 mae=0.003906 max=1; want sum=0 pixels=256 mae=0.000000 max=0` | Sound |
| I16 plane predictor | Plane gradients, shift constants, clipping, H/V orientation | Existing I16 red probes mutate `b/c` shifts, clipping, and H/V | `ALL 4 mutation probes detected — RED proofs complete.` | Sound |
| Intra MB0 fixture | MB0 luma pred/recon and mode guard | Negative RTL perturb plus mode-guard checks | `EXPECTED_RED p3_intra_mb0_negative...`; `P3 intra MB0 Verilator exact check PASS: 16 luma 4x4 blocks matched pred/recon exactly. CAVEAT: MB0 only exercises I4x4 DC/H/V...` | Sound for MB0; scoped, not full-intra proof |
| Intra frame fixture | Whole I-frame luma exactness | Frame-wide negative RTL perturb | `EXPECTED_RED p3_intra_frame_negative...`; `P3 intra frame-wide Verilator exact check PASS: mb_exact=300/300 frame=320x240 luma_pixels=76800...` | Sound |
| Inter prediction vectors | Motion-vector metadata | `MPLEX_P3_INTER_PERTURB=mv` | `FAIL fixture mismatch tests/fixtures/p3_inter_pred/pframe1_mb_v1.json... first_diff line=6` | Sound |
| Inter prediction vectors | Per-frame/per-MB MAE rows | `MPLEX_P3_INTER_PERTURB=mae` | `FAIL fixture mismatch tests/fixtures/p3_inter_pred/frame_mae_v1.csv... first_diff line=1251` | Sound |
| Inter prediction vectors | Baseline/CAVLC/no-B profile envelope | `MPLEX_P3_INTER_PERTURB=profile` | `FAIL baseline guard: synthetic unsupported stream profile=77 level=30 cabac=1` | Sound |
| P16 real-P scoreboard | Prediction, residual, MV, RBSP request, MV-neighbour, scheduled residual, scan order, U/V read | Existing red builds for each fault | Examples: `got=73 want=92 pred=73 residual=19`; `read_ordinal 20736 got_addr=0x4a08 want_addr=0x4808`; `swapped scheduled coefficient fault failed scan-order scoreboard` | Sound |
| Frame-plane goldens | Plane bytes, colorspace provenance, loop-filter provenance | Corrupt first U byte and provenance mutations | `FRAME_PLANE_COMPARE raw frame=0 plane=U exact=19199 pixels=19200 mae=0.003906 max_abs=75`; `test_h264_frame_plane_goldens: OK ... corrupt-plane/provenance RED checked` | Sound |
| Multi-NAL stream path | Explicit expectations, P recon liveness, residual checksum | Refuse implicit defaults, force `recon_sig=0`, wrong expected checksum | `OK refuses implicit unproven defaults rc=2`; `OK red-check forced recon_sig=0 rejected parsed P DPB/MC liveness`; `OK deliberate RED wrong expected checksum rc=1` | Sound |

## Notes

- The 624×480 derived real clip should improve image-statistics realism, but it is not a substitute for the two closed boundary probes: real content may still avoid exact saturated recon pixels or bottom/right clamp edge sentinels.
- The zigzag helper swap `scan 1 ↔ 2` did not fail because those two positions share the same H.264 dequant matrix class; that mutation is behavior-equivalent for magnitude and is not evidence of vacuity.
- The sharper scan-order mutation crosses dequant classes (`scan 1 ↔ 4`) and the RTL testbench now has a direct placement probe, so scan-order failures do not have to wait for a downstream IDCT/recon mismatch.

## Real-content cross-check

The derived 624×480 Constrained Baseline asset is recorded in `docs/derived-validation-assets.md`. As of `01a8aa6`, per-frame Y/U/V hashes are tracked in `tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json`, generated with `-skip_loop_filter all` to match the pre-deblock fabric stage. The full media remains untracked under `build/`; the full 1800-frame check is optional. The always-on committed raw slice is `tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv` with manifest `tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled_v1.json`.

`docs/phase3-decode.md` reports the derived stream as 1800 frames, 12,713,118 Annex-B bytes, and ~20.5% more bytes/MB plus ~29.6% more bytes/P-frame than the synthetic 624×480 P16 fixture. The hash manifest adds scoreability markers: **1790 unique Y-plane hashes**, and **U/V differ on 1774/1800 frames**. The 26 U/V-alias frames are exactly frames `0..25`; they cannot detect a U/V swap and must not be selected as chroma-discrimination slices.

### Properties in the real-content gap

These audited properties are exercised by the derived real-content reference in ways the synthetic fixtures do not cover, or cover only narrowly:

| Property | Synthetic coverage today | Derived-real coverage signal | Priority |
| --- | --- | --- | --- |
| Sustained residual/CAVLC diversity and scan-order placement | MB0 luma plus two scheduled P16 MBs/four scheduled luma residual blocks; good for local proof, narrow for coefficient diversity. | 1764 P frames and higher bytes/P-frame imply many more nonzero residual patterns and scan positions once raw slices are committed. | Highest: use for scan-order/dequant/IDCT/residual slice selection. |
| Long-run Y/U/V plane discrimination | Synthetic DPB patterns and frame-plane goldens are now sound, but short and deliberately shaped. | 1790 unique Y hashes and U/V distinct on 1774 frames give real-image-statistic plane discrimination at 624×480. | High: choose only U/V-distinct frames for chroma slices. |
| Real 624×480 frame-plane final-byte oracle at the fabric loop-filter stage | Synthetic 624×480 frame-plane goldens prove mechanics and provenance, not real-image value ranges. | Per-plane hashes score native I420 with disabled loop filter over 1800 frames. | High once raw slice/candidate comparator is always-on. |
| Sustained throughput/ring lifecycle under realistic packet sizes | Short synthetic clips; good unit vectors, weak sustained workload proxies. | 1800-frame derived stream is the measured ARM-boundary workload. | Medium for numeric correctness, high for performance/lifecycle gates. |
| Motion/reference variability over time | Synthetic P16 motion vectors are mutation-tested but compact. | Real-content temporal changes across 1790 unique frames can catch stale-frame/reference lifecycle defects if slices are spread through the clip. | Medium; requires committed slices or candidate raw output. |

Properties **not closed by real content alone**:

- **DPB upper clamp edge:** real content may not motion-compensate into the bottom/right boundary on demand; the explicit edge-sentinel probe remains required.
- **Recon saturation clipping:** real content may not hit exact 0/255 reconstruction boundaries; the synthetic clip probes remain required.
- **Unsupported stream/profile contracts:** the derived asset is intentionally Baseline/CAVLC/ref=1/no-B and cannot test High/CABAC/B refusal.
- **Chroma on frames 0..25:** U and V hashes alias, so those frames are vacuous for U/V swap detection.

### Slice-selection guidance for W-FEED

A slice picked for coverage should beat a slice picked for position. From the hash-only manifest, the hard constraints are:

1. **Reject frames 0..25 for chroma discrimination** (`U == V`).
2. **Require U/V-distinct frames** for any chroma or U/V-swap coverage.
3. **Spread slices across the 1800-frame run** to catch stale/reference lifecycle drift, not just one local motion region.
4. **Prefer frames with raw-slice evidence of nonzero residual across multiple macroblocks and multiple 4×4 blocks.**
5. **Prefer frames with high Y/U/V variation or edge/extreme samples**, but keep explicit synthetic sentinels for exact clamp/saturation boundaries.

Hash-only seed candidates that satisfy U/V distinctness and temporal spread are: `26, 300, 600, 900, 1200, 1500, 1799`. Final committed slices should be refined from raw frame data/residual parsing, not hashes alone: choose the subset with the most nonzero residual blocks, distinct U/V planes, and any edge-near samples. If a chosen slice includes frame `0..25`, document it as luma/startup-only; it is vacuous for chroma-plane discrimination.

## Gap closures after the real-content slice landed

| Gap | Closure | Mutation | Evidence | Verdict |
| --- | --- | --- | --- | --- |
| Real-content U/V plane discrimination | The always-on 8-frame slice is selected only from U/V-distinct source frames (`149,392,474,710,937,1183,1349,1675`) and the verifier now checks both hashes and per-plane stats. | Swap U and V in every raw I420 frame. | `DERIVED_SLICE_FAIL plane_hash slice=0 source=149 plane=U ...`; `DERIVED_SLICE_FAIL plane_hash slice=0 source=149 plane=V ...` | Sound |
| Real-content chroma byte sensitivity | The verifier red-checks independent single-byte corruptions in U and in V, so chroma is not merely protected by a luma hash or by coherent U/V swapping. | Flip the first U byte, then flip the first V byte, in the committed slice. | `DERIVED_SLICE_FAIL plane_hash slice=0 source=149 plane=U ...`; `DERIVED_SLICE_FAIL plane_hash slice=0 source=149 plane=V ...` | Sound |
| Chroma residual scheduling in the P16 decode scoreboard | The P16 scoreboard now lands 8 scheduled chroma residual blocks per MB and records plane-specific sample failures. | Drop last chroma residual; swap chroma scheduled coefficients; swap U/V chroma residual block classes. | `sample 356 plane=V got=23 want=42 pred=23 residual=19`; `sample 320 plane=V got=207 want=209 pred=190 residual=19`; `sample 256 plane=U got=176 want=164 pred=157 residual=7` | Sound |
| Chroma read U/V discrimination in the P16 decode scoreboard | The reference read scoreboard names the bad read ordinal and address when V reads U or U reads V. | Swap chroma read plane bases. | `read_ordinal 20736 got_addr=0x4a08 want_addr=0x4808` | Sound |

Remaining priority gaps:

- The always-on real-content slice is still a final-byte/hash oracle; it does not localise CAVLC residual syntax, dequant class, or scan position by itself. Keep the synthetic IDCT/direct-placement and P16 scheduled-residual probes.
- Real content increases the chance of edge/extreme values, but exact DPB clamp and recon saturation boundaries still require explicit synthetic sentinels.
- The full 1800-frame derived asset provides better long-run lifecycle/reference diversity when available, but the committed eight-frame slice is the only always-on real-content gate.
