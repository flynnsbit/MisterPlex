# Derived real-content H.264 frame-plane hashes

These fixtures make the derived 624×480 validation asset scoreable for decode correctness without committing the 12 MB media file or an 808 MB raw I420 dump.

The asset is **derived re-encoded validation content**, not original library content and not original-Part direct-play evidence. Provenance for the media file is tracked in `docs/derived-validation-assets.md`.

## Fixture

- Full optional manifest: `derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json`
- Source media path when regenerated: `artifacts/local/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264`
- Source media SHA-256: `41f2769189bdceb3c30315bf557e44e01d016d48c3eca8507ceb6eed51919e04`
- Geometry: 624×480 I420, 449,280 bytes/frame, 1800 frames
- Decoder contract: FFmpeg native H.264 with `-skip_loop_filter all`, output `yuv420p`
- Coverage markers: 1790 unique Y-plane hashes; U/V planes differ on 1774/1800 frames, so U/V swaps are scoreable on most of this clip but not on the initial grey/low-chroma frames.

## Always-on bounded slice

`derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv` is a
tracked 8-frame native-I420 slice (3.43 MiB) decoded at the same disabled-loop
filter stage. It is the always-on unit fixture for clean checkouts where the
full derived media under `build/` is absent.

Selected source frames: `149,392,474,710,937,1183,1349,1675`. They were chosen
across the clip for distinguishable U/V planes, high luma/chroma variation, and
clamp-edge coverage. The slice manifest records:

- `uv_distinct_frames=8/8`, so a U/V swap is scoreable on every selected frame
- `unique_y_hashes=8/8`
- `y_min=0`, `y_max=243`

### Filter-enabled companion (deblock gap control)

`derived_realcontent_624x480_baseline_ref1_nob_8f_i420_enabled.yuv` is the same
eight source frames decoded with FFmpeg's **default in-loop deblocking enabled**
(no `-skip_loop_filter`). It is a companion control, not a replacement: the
disabled fixture remains the product pre-deblock oracle other lanes depend on.

The enabled companion exists so the decode-core real-slice scoreboard can measure
how much of the pre-deblock green survives contact with a filter-enabled
reference. That survival is expected to be low on P-content because filtered
references cascade through motion compensation, not only because edge samples
change inside one MB.

Regenerate both slices from the full asset:

```bash
python3 tools/derived_h264_slice_fixture.py generate \
  --input artifacts/local/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264 \
  --slice-out tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled.yuv \
  --manifest-out tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_disabled_v1.json \
  --frames 149,392,474,710,937,1183,1349,1675 \
  --h264-loop-filter disabled

python3 tools/derived_h264_slice_fixture.py generate \
  --input artifacts/local/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264 \
  --slice-out tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_enabled.yuv \
  --manifest-out tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_8f_i420_enabled_v1.json \
  --frames 149,392,474,710,937,1183,1349,1675 \
  --h264-loop-filter enabled
```

## Regenerate / verify

```bash
python3 tools/derived_h264_plane_hashes.py generate \
  --input artifacts/local/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264 \
  --manifest-out tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json \
  --h264-loop-filter disabled

python3 tools/derived_h264_plane_hashes.py verify \
  --manifest tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json
```

To score a candidate decoder output, emit native I420 at the same loop-filter
stage and compare it explicitly:

```bash
python3 tools/derived_h264_plane_hashes.py verify \
  --manifest tests/fixtures/derived_validation/derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json \
  --candidate-planes build/path/to/candidate_624x480_1800f.i420 \
  --candidate-colorspace I420_NATIVE
```

The unit check always verifies the bounded slice and mutation-proves it with a
corrupted Y-plane hash and a U/V-swapped raw slice. When the untracked full asset exists under `artifacts/local/arm-profile-sample/`,
it also verifies the full 1800-frame manifest; otherwise the full check is
reported as `ASSET_EXPIRED` optional info, not as a pass.

```bash
tests/unit/test_derived_validation_hashes.sh
```

If the full asset has been cleaned, regenerate it with
`scripts/regenerate_arm_profile_asset.sh` and verify it with
`scripts/check_arm_profile_asset.sh`.

## What this can detect

A candidate decoder that emits native I420 at the same loop-filter stage can be scored frame-by-frame and plane-by-plane against these hashes. Any changed final byte in Y, U, or V changes the corresponding plane hash. That makes real-content failures in residual add, scan order, dequant/IDCT, motion compensation, reference selection, chroma placement, and U/V ordering visible when this clip actually exercises the affected samples.

## What this cannot detect

- It does not prove original library coverage; the source was HEVC `/metadata/3` re-encoded to H.264.
- It does not score enabled in-loop deblocking, RGB/RGB565 presentation, pillar masking, or timing/drop/repeat behaviour.
- It does not localize a mismatch beyond frame and plane unless a comparator also computes pixel diffs.
- It cannot catch a mutation that the content does not express. For example, a scan-position swap can be invisible if the swapped coefficients are both zero or share an equivalent dequant class for all exercised blocks.
- It is a reference-output oracle, not a parser-coverage proof; a decoder can match these frames while still having unsupported-stream bugs elsewhere.
