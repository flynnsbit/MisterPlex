# Controller correctness and capacity fixtures

## Real-picture, legally filter-disabled IDR

`real_color_filter_off_320x240_1f.264` contains one 320x240 baseline IDR.
Its SHA-256 is
`003cdb64a16913b7d84cc9a35707a23892d8c57acd95e10078c1d398dd00ac71`.
The Annex-B file is 7,445 bytes; its VCL RBSP is 6,841 bytes.

The source picture was decoded normally from
`../p3_host_recon/plex_real_baseline_320x240_1f.264`, then encoded as new
bytes with:

```sh
ffmpeg -hide_banner -loglevel error -nostdin -threads 1 \
  -i tests/fixtures/p3_host_recon/plex_real_baseline_320x240_1f.264 \
  -frames:v 1 -pix_fmt yuv420p -c:v libx264 -threads 1 \
  -profile:v baseline -qp 24 \
  -x264-params 'cabac=0:no-deblock=1:keyint=1:ref=1:bframes=0:8x8dct=0' \
  -f h264 output.264
```

The encoded header signals `disable_deblocking_filter_idc=1`. Its actual
slice QP is **21**: PPS initial QP 24 plus slice delta -3. The `-qp 24`
encoder argument does not imply that this I picture has slice QP 24.
Its SPS signals `max_num_ref_frames=0`, which is legal for this all-IDR
picture and is distinct from the PPS default active L0 count. The controller
must admit it without making the displayed bank eligible for later P prediction.

Compare these exact bytes against ordinary FFmpeg decoding. Do not disable
filtering in the reference decoder, patch slice flags, or inject reference
pixels, coefficients, or motion vectors into the DUT. This fixture does
not qualify the original filtering-enabled bytes and provides no temporal
or inter-picture proof.

## Exact 64 KiB VCL RBSP

`capacity_320x224_65536rbsp.264` is an ordinary x264 encoding of deterministic
procedural YUV pixels. Its complete VCL RBSP is exactly **65,536 bytes**,
so successful decoding ends at bit cursor **524,288**. Coded geometry is
320x224, cropped to 320x212. SAR is not signaled and remains unknown (0/0);
it must not be replaced with 1:1 or used to infer the original source DAR.

Pixel entropy was selected before encoding to reach this size; no encoded
header, residual, filter flag, or trailing bits were patched. The adjacent
JSON records the source-pixel recipe, encoder parameters, and SHA-256.
The complete Annex-B file also contains framing and emulation-prevention
bytes; those are not part of the RBSP capacity count.

This is a controller capacity/EOF regression, not a claim about the
recorded PMS movie, its original display aspect ratio, sustained frame
rate, or hardware acceptance. References remain ordinary FFmpeg output.

## Immutable native-picture lease

Run the controller with its optional source-copy lease enabled:

```sh
P2_RBSP_ADDR_W=13 P2_NATIVE_PUBLISH_LEASE=1 \
  tests/unit/test_p2_intra_controller.sh \
  tests/fixtures/gop12_oracle_color_filter_off/textured_color_fractional_filter_off_320x240_12f.264
```

The test reads every coded sample through the existing native RAM write
port after successful promotion, concurrently with RGB reads on the other
port. Alternate frames release the lease before or after RGB completion;
the bank and metadata cannot be reused until both consumers finish.
`frames_out` and `done` still describe accepted legacy RGB completion,
not the native notification or actual display presentation.

`P2_NATIVE_CANCEL=reset` or `P2_NATIVE_CANCEL=vcl` cancels the first lease
with accepted reads in flight, then replays the encoded picture. The full
lease-enabled suite includes both cases. The modeled copy/drain fence is a
component ownership check, not a DDR/display throughput measurement; actual
safe-swap cadence and generation cancellation require the source pipeline.
