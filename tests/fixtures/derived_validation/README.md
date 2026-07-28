# Derived real-content H.264 frame-plane hashes

These fixtures make the derived 624×480 validation asset scoreable for decode correctness without committing the 12 MB media file or an 808 MB raw I420 dump.

The asset is **derived re-encoded validation content**, not original library content and not original-Part direct-play evidence. Provenance for the media file is tracked in `docs/derived-validation-assets.md`.

## Fixture

- Manifest: `derived_realcontent_624x480_baseline_ref1_nob_1800f_i420_hashes_disabled_v1.json`
- Source media path when regenerated: `build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264`
- Source media SHA-256: `41f2769189bdceb3c30315bf557e44e01d016d48c3eca8507ceb6eed51919e04`
- Geometry: 624×480 I420, 449,280 bytes/frame, 1800 frames
- Decoder contract: FFmpeg native H.264 with `-skip_loop_filter all`, output `yuv420p`
- Coverage markers: 1790 unique Y-plane hashes; U/V planes differ on 1774/1800 frames, so U/V swaps are scoreable on most of this clip but not on the initial grey/low-chroma frames.

## Regenerate / verify

```bash
python3 tools/derived_h264_plane_hashes.py generate \
  --input build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264 \
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

A convenience check is available when the untracked asset exists:

```bash
tests/unit/test_derived_validation_hashes.sh
```

If the asset has been cleaned from `build/`, regenerate it first using `docs/derived-validation-assets.md`.

## What this can detect

A candidate decoder that emits native I420 at the same loop-filter stage can be scored frame-by-frame and plane-by-plane against these hashes. Any changed final byte in Y, U, or V changes the corresponding plane hash. That makes real-content failures in residual add, scan order, dequant/IDCT, motion compensation, reference selection, chroma placement, and U/V ordering visible when this clip actually exercises the affected samples.

## What this cannot detect

- It does not prove original library coverage; the source was HEVC `/metadata/3` re-encoded to H.264.
- It does not score enabled in-loop deblocking, RGB/RGB565 presentation, pillar masking, or timing/drop/repeat behaviour.
- It does not localize a mismatch beyond frame and plane unless a comparator also computes pixel diffs.
- It cannot catch a mutation that the content does not express. For example, a scan-position swap can be invisible if the swapped coefficients are both zero or share an equivalent dequant class for all exercised blocks.
- It is a reference-output oracle, not a parser-coverage proof; a decoder can match these frames while still having unsupported-stream bugs elsewhere.
