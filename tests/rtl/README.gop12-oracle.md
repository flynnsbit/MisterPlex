# Source-bound GOP12 decoder oracle

Run from the repository root:

```sh
tests/unit/run_gop12_fpga_sim.sh
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree
tests/unit/run_gop12_fpga_sim.sh \
  --fixture tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_320x240_12f.264
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree --require-color-motion \
  --fixture tests/fixtures/gop12_oracle_color/textured_color_fractional_320x240_12f.264
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree --frames 2 --au-publish --au-input-limit 8192 \
  --fixture tests/fixtures/p2_oracle_intra_in_p_filter_off/intra_in_p_320x240_2f.264
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree --au-publish --require-color-motion \
  --fixture tests/fixtures/gop12_oracle_bidirectional/bidirectional_color_sar1_filter_off_320x240_12f.264
```

The default is donor commit `00e187d0771223cdc41a604de89b65b1443d4d4a`,
not a prebuilt executable or the changing integration RTL. `worktree` snapshots
only the named decoder sources and read-only bench, detects source changes during
snapshotting, and records both the base commit and every actual file hash.
Neither mode modifies RTL.

The launcher builds under `build/verilator/gop12-oracle/<input SHA256>/`.
Its immutable selected-input snapshot preserves source licenses and the fixture
README. The build key includes RTL, included header, bench, launcher, fixture,
compiler/Verilator binaries, versions, flags, and relevant environment. A changed
input builds a new binary; a corrupt existing snapshot/binary fails rather than
being silently reused. `--reuse-only` refuses missing exact builds.

Each invocation creates fresh actual native I420 bytes, frame records, an
ordinary FFmpeg decode, FFprobe frame/packet metadata, encoded slice headers,
and `result.json` plus its hash. `--verify-result PATH` checks a recorded run
against the requested inputs and verifies actual artifacts, not just a score.
Consecutive identical RTL diagnostic lines are run-length summarized.

## Causal boundary and scoring

Only fixture Annex-B bytes reach the DUT. The bench **observes** native DPB
address/data/write strobes; it never injects pixels, reference frames, residuals,
or writes the donor's `clip_gold_match` latch. Every completed picture must have
all 115,200 native Y/U/V samples written. Exact comparison includes all three
planes of all twelve pictures; no mismatch tolerance or expected-red waiver
exists. Missing output, partial pictures, timeouts, identity errors, and stale
artifacts are nonzero failures.

Ordinary FFmpeg honors the encoded deblocking flags. No `skip_loop_filter`,
`nofilter`, or reconstruction postprocessing is used. FFmpeg's `trace_headers`
independently supplies `frame_num` and deblocking syntax; FFprobe packet byte
ranges bind the VCL identity to each decoded picture. Raw Annex-B has no
container PTS: missing timestamps remain explicitly null. This exact lane
requires 320x240 I420, twelve single-slice pictures, and I/P display order.

Every run isolates scorer/provenance negative controls: wrong oracle byte,
frozen first-frame replay, wrong source key, and a missing actual-output file,
with a scorer self-comparison baseline and separate U/V perturbations.
These checks are not DUT correctness
evidence. DUT acceptance still requires fresh actual output.

On timeout the bench also saves **only written** native samples and failure
phase/MB/bit-position in a partial diagnostic. Its comparison excludes unwritten
locations and never constitutes a completed-frame score.

## Scope limitations

The constrained donor fixture (`9b49b7366c2be202ea2e26994c4f13d05dd82f3741fc3505a33e029e38e8632b`)
has 95.3% P skip, neutral chroma, no intra-in-P and no I16 plane. A green result
cannot establish chroma-residual handling, general intra/inter correctness,
complete filtering, or product readiness. Earlier nofilter IDR scores are not
equivalent evidence.

The bench paces each NAL until reconstruction and paint complete. Reported
cycle fields distinguish VCL injection through the last accepted native write
from injection through the `frames_out` signal. The latter may include RGB
drain/commit in newer controller revisions; it is not assumed to be the native
grid-completion cycle. Neither metric is wall-clock throughput, a target
frequency, DDR ingestion, HDMI presentation, or Plex
play/cast. The source's native DPB may be correct on this fixture while its
presentation remains grayscale. Hardware/PMS operations belong to the operator.

## Color, fractional motion, and border extension

The original procedural `gop12_oracle_color` fixture adds non-flat Y/U/V,
ordinary I4/I16 (including plane), and fractional 16x16 P/skip reference motion.
Its generator, source-pixel hash, encoded-byte hash, ordinary x264 command and
encoder log are preserved in adjacent provenance. Source pixels are **not**
reconstruction references and are never supplied to the RTL.

`--require-color-motion` builds an independent libavcodec motion-export observer
using existing `pkg-config` libavformat/libavcodec/libavutil development packages.
The build key additionally binds observer source, compiler/link flags, library
versions/hashes and resulting binary. It decodes the same frozen Annex-B bytes
with default filtering and records every exported motion vector.

`motion.footprints.jsonl` also records each vector's destination, signed actual
MV (not MVD syntax), qpel/eighth-chroma phase, and inclusive pre-clamp luma
six-tap/chroma-bilinear bounds. Negative displacement uses floor division.
The luma rectangle bounds sparse cross support for odd/odd phases; it does not
assert every address was fetched by RTL. Chroma border counts are separate
from the required luma border counts. Exported reference direction alone is
not a unique reference index; single-reference syntax must independently hold.

Coverage requires all sixteen luma quarter-pixel phase pairs, fractional chroma
motion, interpolation support crossing all four picture borders, past-reference
16x16 vectors, all four fractional-chroma borders, and varying decoded Y/U/V
in every picture. The separate bidirectional fixture targets the missing chroma
edge coverage of unidirectional movement. Exported 16x16 vectors
include inferred skip vectors; they are not a count of coded P16 macroblocks.
Coverage qualification alone cannot pass the gate: the composed DUT must still
produce twelve complete, independently matching native pictures. The neutral
donor fixture must fail this stricter mode even if its narrow pixel score is zero.

## Isolated real IDR diagnosis

Named fixture sidecars (`same-basename.json`) are frozen along with the README;
declared Annex-B hashes and encoded filtering flags are checked. Ordinary
header identities now include PPS initial QP, slice delta, and their actual
slice-QP sum. Encoder `-qp` arguments are not substituted for that syntax.

`--frames 1 --fixture PATH` explicitly isolates one 320x240 I420 IDR. It still
requires actual native writes, complete all-plane coverage, ordinary FFmpeg
comparison, encoded slice identity, and source/output binding. The fixture must
have an adjacent provenance README. An optional
`required_disable_deblocking_filter_idc` in its provenance JSON is checked
against independently traced encoded syntax, never forced in the decoder.

Single-picture results make no temporal, inter-reference, frozen-frame replay,
or GOP claim. Their negative control rejects constant-zero output instead of
claiming that first-frame replay can be detected from one picture.
`--require-color-motion` is therefore deliberately incompatible with this mode.
`--frames 2` similarly isolates an exact I/P pair, including constrained-intra
reference-neighbor regressions. It retains the frozen-first-frame negative
control but cannot establish multi-GOP lifetime or sustained throughput.

When the composed controller exposes the new DPB lifetime interface, observation
uses actual write acceptance (`mem_we` and downstream readiness), not held-valid
requests. Completion additionally requires a real promotion pulse, no reference
or decoder error, and 76,800 accepted RGB writes at the stream output. These are
observations only: the bench never forces promotion, frame-done or drain signals.
Promotion is captured together with the authoritative reference base/width/height
and unique accepted sample coverage at that exact cycle. Later writes cannot
retroactively make an early or wrong-bank promotion valid.
Older pinned always-ready BRAM runs explicitly record that lifetime observation
is unavailable and cannot establish the newer completion contract.
Where the frontend exposes a legacy/modern selector, its actual selected
parameter is observed and recorded. A legacy-diagnostic selection is not
accepted as current bounded-decoder verification, even if pixels coincide.
The bench does not force internal AU validity, EOF, metadata, or idle signals
to get around an unavailable bounded-decoder input route.

Native decoder sample range is retained: full-range `yuvj420p` is not converted
to limited-range `yuv420p` for comparison. Each frame records encoded range and
matrix metadata. Where controller latches are available, their full/limited
range and BT601/BT709 selection must match the ordinary decoder metadata.
Unspecified matrix uses the bounded BT601 fallback. This does not claim
bit-exact RGB rounding: RGB output acceptance counts are checked, not RGB pixels.

## Numerical reproduction versus supported-stream qualification

The current composed decoder has no complete signaled-filter scheduler and
always promotes completed reference pictures. Consequently **encoded
`disable_deblocking_filter_idc=0/2` or `nal_ref_idc=0` is a fatal qualification
error**, even if a restricted picture happens to match numerically. There is
no waiver flag and no oracle filter override.

The default historical donor fixture signals filter-on. Its independently
measured zero-error native bytes remain available, but the current gate exits
nonzero for its unsupported filter requirement. This does not change expected
pixels or erase historical results. Use genuinely encoded filter-off fixtures
for supported-filter checks; broader decoder/profile/glass claims remain
separate. Future filter-on qualification requires a real scheduler, not merely
leaf filter arithmetic or coincidental neutral-picture equality.

## Real-PMS handoff verification

`python3 tests/unit/check_pms_capture_oracle.py --handoff PATH` consumes an
existing lab handoff; it never operates PMS or hardware. It verifies and freezes
every named capture artifact, independently re-decodes bounded `delivered.264`,
and compares every cropped native Y/U/V frame with the supplied ordinary
`framemd5`. Elementary, bounded-remux TS, and original-network TS packet payload
hashes must agree before original PTS are attached. Network read-ahead beyond the
bounded capture is not decoded/scored. Exact first-AU prefixes are copied without
re-encoding or changing SPS/PPS/filter flags; original PTS are retained separately.
`--start-frame N --prefix-frames 12` selects a contiguous window starting at an
actual IDR, while retaining original source indices, byte offsets and PTS.
This permits testing the maximum-size IDR without substituting an easier first
picture. The generated window has an adjacent capture-provenance README and
an AU-hash-bound `original-pts.json` usable by the real DDR/native lane.

SPS coded dimensions and crop are recorded separately from ordinary decoder
display dimensions. No resize, padding, cropping override, or native-geometry
claim is permitted to force a capture into the 320x240 bench. Actual VCL RBSP and
AU byte maxima are checked independently against frontend and transport limits.
The capture assessment reports the assigned modern64KiB AU/RBSP target and a
separate explicit legacy8KiB assessment. Neither constitutes evidence that
source RAM/scanner, controller address/length/cursor widths, or publisher
geometry have actually been integrated. The 17494-byte PMS IP AU fits64KiB,
not the old8KiB model; it must not be silently clipped.

Absent SPS aspect-ratio signaling stays **unknown SAR 0/0 and absent bitstream
DAR**. The independent Plex `source.json` aspect ratio (1.66 for these captures)
is preserved verbatim, never replaced with 320/212. A separate ordinary decode
with `-apply_cropping 0` exposes all coded rows without changing filtering.
For coded320x224, its packed I420 plane bases are 0/71680/89600, strides
320/160/160, and size107520. Per-plane row extraction must reproduce the
default visible320x212 reference (101760 bytes) exactly for every frame.
Taking a packed byte prefix is checked as a negative control. These packed
offsets are **not** the fixed320x240 FPGA allocation's 0/76800/96000 offsets:
any future FPGA comparison must use the implemented source plane bases/strides.

This extension deliberately exits nonzero when actual RTL output is absent,
even when all 192 ordinary frame hashes match. Its
`reference_verification_passed` is not FPGA, throughput, audio, playback, or glass
acceptance. Real capture bytes remain in ignored build storage, not test sources.
The checker also accepts an operator's single-case `oracle-handoff.json`
containing `origin`, `frames`, and a `sha256` map. Declared hashes are checked;
additional required artifacts are explicitly labeled as observed-at-freeze,
not retroactively claimed as operator-hashed. Original full-size rejection
status/reason remains separate from ordinary-reference equality.
Multi-capture `captures` handoffs retain each operator hash, source label and
reported subtitle-visual failure independently of numeric decode results.
Original23976 PTS are checked as an exact15015/4 tick period at90kHz: increments
3753/3754 and cumulative quantization span below one tick, not forced to24fps
or rewritten into a constant integer duration.

## Real DDR-AU decoder/publication producer

For an independent whole-GOP **decoder** lane, use the shared, reader-tested DDR
BFM rather than the source owner's two-picture publisher producer:

```sh
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree --ddr-native \
  --au-input-limit 8192 --fixture-timeline --require-color-motion \
  --fixture tests/fixtures/gop12_oracle_bidirectional/bidirectional_color_sar1_filter_off_320x240_12f.264
```

The explicit8192 selects the earlier model scope; omitting it requests the
assigned modern65536 input limit and refuses a source still configured8192.
`--ddr-native --frames N` supports explicit bounded captures of1..256 frames,
while the default remains12 and legacy/publication selectors remain1/2/12.
For example, an operator's complete191-frame capture must be requested as191,
not described as full-stream proof after testing only its first12 AUs.
This path freezes `ddr_bitstream_ring_bfm.hpp` with its real record/AU serializer,
DDR pre-edge response/acceptance and post-edge retirement model. It performs
reset-epoch ACK, nonce-matched Probe, Begin, every complete AU, and Drain through
the actual reader and `stream_path`; it does not manufacture internal readiness,
geometry, NAL identity, EOF, native samples, residuals, or reference state.

The accepted-write observer maps actual coded rows from the observed native
allocation offsets/strides. It checks unique coverage at native promotion,
reference bank/geometry, actual held AU metadata, actual SPS crop/SAR, and every
controller-accepted visible RGB word before completion. RGB words are captured
from the controller side, not the legacy outer `fs_*` mux: that mux can hide
first-picture paint while its frame counter is still zero.

The default independently decoded reference includes all **coded** rows with
normal filtering. Width/height/crop are never injected into the decoder.
`--pts-sidecar PATH` requires the preserved original PTS sidecar to match each
exact AU hash. For timestamp-free local fixtures, `--fixture-timeline` explicitly
requests a synthetic timeline at the stream's declared rate; those values are
never labeled original PTS. Neither mode invents metadata inside the BFM helper.

This decoder-only configuration sets `ENABLE_PICTURE_PUBLISH=0`. It does **not**
prove the separate native publisher, DDR frame store, MVPS, scanout, or hardware.
Cycle observations include DDR latency and sequential host pacing, not sustained
throughput. The existing `--au-publish` route remains separate:

`--au-publish` reuses the source owner's existing
`fpga_video_publish_tb` without editing it. The launcher freezes its QIP-named RTL,
literal includes, C++/SV producer, and host ABI headers before compiling from
that immutable snapshot. `FULL_AU=1`, `FULL_AU_RTL=1`, `FULL_AU_FRAMES=N`, and
`INTEGRATE_STREAM=1` are mandatory, so the controlled native-data path is
disconnected. Concurrent builds of the same input key are serialized.

The first selected 1, 2, or default 12 complete access units are copied byte-for-byte from the supplied
Annex-B fixture; they must start with an IDR, retain actual keyframe flags, fit
the selected input bound, and decode to 320x240 with explicitly encoded square
SAR. The modern input target defaults to65536; `--au-input-limit 8192` explicitly
retains the earlier model scope. An old producer still hardcoding8192 refuses
the modern target before compilation; the harness never silently substitutes
that smaller model for assigned64KiB integration. An older selected producer lacking the frame-count extension refuses
counts other than its original two; no prebuilt fallback is used. The producer performs real
ring Probe/Begin/Pause/AUs/Resume/Drain, decoding, native publication, DDR
frame-store safe swap, and MVPS checks. Its actual DDR picture file is rescored
independently against freshly decoded ordinary Y/U/V. Missing bytes or published
identities cannot pass.

With `--pts-sidecar PATH`, the two-picture producer requires the frozen
`original-timing.txt` under `FULL_AU_ORIGINAL_TIMING=1`, and uses those exact
PTS/duration/timebase values for transport and MVPS checks. Missing timing is
fatal; no synthetic fallback is allowed. Without that option the historical
synthetic signed transport PTS `-12345 + frame*1001` at `1/24000` remain explicitly
**not** original media/PMS timestamps or rate.
It fixes the renderer to limited BT601, and checks selected RGB pixels rather
than complete RGB numerical conformance; other range/matrix metadata cannot
qualify in this mode. Individual native-write coverage and RTL frame numbers
are not directly logged by this reused producer, unlike the read-only native
bench. Publication system-cycle observations include decoder, publisher and
BFM waits; they are not isolated core throughput. A two-picture result is not
GOP evidence. Neither a twelve-picture result nor synthetic transport timing
is sustained-throughput, original-PMS timing, hardware, or glass qualification.

The separate square-SAR color encoding preserves all twelve VCL payloads from
the historical filter-off color fixture. Both original fixtures remain
unchanged; the earlier absent-SAR input is correctly rejected by the current
frontend before slice parsing, not evidence of a CAVLC parsing failure.

### Opt-in runtime geometry preparation/scoring

`--au-publish --au-runtime-geometry --frames 2 --pts-sidecar PATH` selects the
bounded runtime-geometry contract. Without `--au-runtime-geometry`, the existing
full320x240 invocation remains unchanged. The source-owned producer must support
`FULL_AU_RUNTIME_GEOMETRY=1`; this helper does not change its bench or RTL.
Execution remains deferred during the coordinator's a06 fit freeze.

The runner derives six **pixel-unit** integers from the selected delivered SPS:
`coded_w coded_h crop_left crop_right crop_top crop_bottom`. These alone form
`geometry.txt`; no nominal dimensions, geometry normalization, or synthesized SAR
are supplied. An ordinary default decode produces the packed visible
`oracle.i420`/`reference.yuv`. A separate ordinary `-apply_cropping 0` decode
produces `reference-coded.yuv`. Filtering is unchanged in both. Per-plane row
extraction must map the latter to the former exactly. Both references, the
geometry sidecar, original AU-hash-bound timing, and their generating helpers
are frozen/hash-bound before simulation.

The required actual-output contract is:

| Artifact | Contents |
| --- | --- |
| `actual.i420` | Two packed **visible** I420 pictures, in published AU order |
| `actual.i420.allocation` | Two actual DDR allocations, each exactly115200 bytes, in the same AU order |

The allocation filename is the producer's supplied actual-output path plus
`.allocation`. The source-owned bench must dump its actual DDR-read allocation
**before** reference/padding assertions, never generate that dump from references.
Missing, partial, extra, or mismatching allocations fail even when visible bytes
match. This dump is a pending source integration dependency, not a producer
internal score accepted as independent evidence.

The independent scorer uses physical Y/U/V bases0/76800/96000 and
strides320/160/160. It separately compares every **coded** sample with the ordinary
uncropped reference, inspects allocation storage outside that coded rectangle
for the publisher's Y16/U128/V128 padding, and compares the actual plane/row crop
with both packed actual output and the default reference. Encoded crop margins
remain coded samples, not padding. Negative controls include a corrupt hidden
coded margin that leaves visible bytes unchanged, per-plane padding corruption
where padding exists, missing allocations, wrong Y/U/V references, frozen-frame
replay, and a stale build key. Immutable result replay rescans the actual
allocations and both references; a score JSON alone is insufficient.

Unknown SAR stays0/0. Independent Plex DAR stays verbatim, including `1.66` and
its exact rational83:50; it is never replaced by320/212. Results explicitly scope
`pass` to pixel/padding/publication evidence and retain
`native_dar.qualified=false`. Cropped-byte equality, and even a local presenter's
DE/RGB log, do not prove the scaler's native DAR or AutoFit. Applying83:50 to a
larger padded active canvas is **not correct**: the genuine cropped content
aperture must reach the scaler and AutoFit must remain intact. No such
VIDEO_AR/AutoFit output-signal qualification is claimed by this scorer, nor any
hardware, audio, or24fps acceptance.

Add `--au-native-beam` to explicitly select the source-owned `present_core`
CE/DE/RGB raster assertions. The immutable build binds `NATIVE_BEAM=1`,
`DDR_FRAME_STORE=1`, `FULL_AU_NATIVE_BEAM=1`, and matching SV/C++ scan-doubling
values. Scan doubling defaults to1; `--au-native-scandouble 0` selects native
undoubled rows. The source shell gate's default does not implicitly change this
launcher's selection. Every requested native-raster observation must identify
the corresponding AU and match the selected visible height and scan mode.
These remain source-producer RGB assertions, not independently rescored raw RGB
or VIDEO_AR/AutoFit proof. The presenter's fixed model timing, including
`content_fps=24`, does not establish original24000/1001 display cadence; original
transport timestamps are never rewritten.

`--au-idr-only` selects the existing producer parameter
`-GIDR_ONLY_PROFILE=1`; it models the static intra policy, not all product
audio/UI capabilities. It does not override the held arbiter's RAM backend.
For a second preserved case on the **same** acquired source cohort, use
`--source-pin worktree --source-build build/verilator/gop12-oracle/KEY`.
The complete RTL/bench/ABI set then comes from that verified immutable build,
including both literal parser-header includes, rather than from the moving
worktree. A separate fixture/timing binding is produced, while
`source_cohort_sha256` remains identical. Changed oracle helpers are rejected;
the original source snapshot and earlier runs are never edited.
