# Identity fixed-output barrier (rd-duck race)

## Defect (quoted)
8e5e0 identity fail-close does NOT prove zero corrupt publishes. Geometry is on
stderr; raw frames on stdout. No cross-pipe ordering: reader can publish a
mixed frame before stderr sets `identityGeomAbort_`. `presentCleanFrame` checked
the atomic once at entry. Unit tests only hit the pure policy helper.

## Fix
Product identity-class plans no longer emit empty-vf `identity_skip`.
They emit `scale=CW:CH:flags=neighbor` with:
- `fixed_output_barrier=1`
- `identity_skip=0`
- `scale_applied=0` (not product ARM resample class)

FFmpeg then emits whole frames at coded WxH even if input size changes —
raw reader cannot assemble mixed old/new rasters. stderr abort is diagnostic.

Also: re-check `identityGeomAbort_` under `presentMu_` immediately before DDR
publish (closes entry-check race for residual raw identity_skip / lab Off).

## Race model (unit)
`identityRawRacePublishWindow(change_at, abort_observed_at)` documents how many
frames a barrier-less reader could still publish — proves stderr cannot interlock.

## Tests
`test_ffmpeg_vf` PASS true rc=0  
`test_yuv420p_chroma_480p` PASS true rc=0  
misterplexd rebuild true rc=0
