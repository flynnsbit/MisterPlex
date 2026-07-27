# Phase 3 frame-plane goldens

These fixtures are additive to `misterplex.p3.mb_golden.v1`. They use
`format=misterplex.p3.frame_planes_golden.v1` and provide byte-exact I420/YUV420p
reference planes decoded by FFmpeg from the checked-in Annex-B multi-NAL streams
with the in-loop deblocking filter disabled (`-skip_loop_filter all`), matching
the current stream-path/RTL output contract.

Each JSON manifest records:

- bitstream path, byte count and SHA-256
- `misterplex.p3.nal_sequence.v1` manifest path, byte count and SHA-256
- FFmpeg/FFprobe version, decode command, and `decoder.loop_filter=skip_loop_filter=all`
- provenance that declares native decoded planes, I420/YUV420p pixel format, no
  RGB/RGB565 round-trip, no presentation border/pillar mask, and
  `provenance.h264_loop_filter=disabled`
- coded/display geometry, `colorspace=I420_NATIVE`, and I420 plane strides
- per-frame frame number, slice kind, plane byte offsets and per-plane SHA-256

Consumers must verify the source hash, sequence hash, geometry, frame count and plane blob
hash before comparing. `tools/extract_h264_frame_planes.py --verify` performs that refusal
check. Candidate comparisons must declare `--candidate-colorspace I420_NATIVE`;
unknown or RGB565-derived candidates are refused with rc=9 before byte comparison, as are
manifests that declare any RGB/RGB565 round-trip or presentation border/pillar masking.
Goldens with an unknown or enabled loop filter are also refused before comparison.
Accepted native I420 candidates are compared plane-by-plane with raw exact/MAE/max_abs.

Regenerate and verify:

```bash
tests/unit/test_h264_frame_plane_goldens.sh
```

The unit gate regenerates all blobs, compares them to the checked-in goldens, verifies
provenance, then flips one byte in frame 0 U and proves the plane comparison goes RED.
It also proves unknown and mismatched candidate colorspaces go RED instead of grading stale
or RGB-round-tripped data as native planes.

The checked-in coverage includes:

- `wcap_residual14_idr_plus_p`: 320×240, 2 frames, IDR+P
- `plex_inter_p16_320x240_12f`: 320×240, 12 frames, 1 IDR + 11 P
- `plex_inter_p16_624x480_12f`: settled 624×480 geometry, 12 frames, 1 IDR + 11 P,
  I420 strides Y=624 and U/V=312
