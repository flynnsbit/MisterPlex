# Bounded real-PMS Baseline experiments

These are **two stream prototypes on one player**, not released FPGA capabilities:
normally compressed all-IDR (`idr`) and constrained single-reference I/P (`ip`).
Neither an HTTP success, a profile XML, nor the probe's syntax pass certifies
FPGA reconstruction, performance, picture quality, audio, or Web casting.

**Current acquisition budget is closed:** the authorized source146 OFF/ON pair
completed under verified v7. All unrun older diagnostic and v8/v9 acquisition
handoffs are superseded, not permission for third/fourth captures. Do not
regenerate the fixture or relabel v7 evidence as a newer bundle. Retained
preparation commands below require a separate future authorization to run.

**Real-PMS bounded characterization complete:** title139 at native24/1, both
I/P and normally compressed all-IDR, each with encoder-signaled filtering on
and off;192 pictures per case passed syntax, timing/bounds, and ordinary decoding.
**Additional real-PMS coverage complete:** synthetic MPEG-2 source145 at
native24000/1001 produced full coded/visible320×240 in all four prototype/filter
combinations,191 pictures each, fitting both8192-byte budgets. This covers
synthetic-source transcoding, not representative non-H.264 movie quality.
The subtitle-requested fifth case **failed visual burn verification**.
**Final targeted pair complete:** new RGB601 source146, all-IDR/filter-off at
native24000/1001, produced191 full320×240 pictures per case with explicit
limited range/matrix6 and both8192-byte bounds satisfied. Subtitle OFF has no
caption; ON visibly burns the expected cue in ordinary decoded3s/5s pictures.
This used the operator's verified new-Part-only selection/restore procedure,
not the ignored query parameter alone.
**Still open:** general session-scoped subtitle selection, representative non-H.264 movie coverage,
source-aspect presentation, representative quality/long-run headroom, FPGA
conformance/performance, A/V, native output, and LAN Web cast/glass acceptance.
**Capacity conclusion:** title139 I/P peaks17494 encoded bytes /17449 RBSP bytes
exceed both8KiB and16KiB. They fit a64KiB test envelope only if that capacity is
actually implemented, verified, and advertised by the live consumer; no such
capacity is inferred from mean size or a transport bench. Prior8KiB-budget
results remain explicit failures for that title. Source145 I/P fits at7324/7279
bytes; this does not establish universal I/P headroom. Neither byte fit nor profile validation
establishes decoder features, DMA/CDC correctness, or hardware admission.
**Color distinction:** older source139/145 outputs omit video-signal/
color-description VUI. Limited range is inferred by H.264's default, but the
matrix is unspecified—not proven BT.601. They fail the strict limited-BT.601
signaling gate without changing any encoded bytes. Source146's actual PMS
output passes strict limited-BT.601 signaling; primaries/transfer remain
genuinely unspecified. Hardware color reproduction and glass remain unqualified.

The old `MiSTerPlex.xml` is retained as a historical recovery asset from
`3f16edc0`. It requests GOP50/min25, up to640x480 at30fps. It is **not** all-IDR,
does not request filtering-off, and is not installed by these experiments.
The old exact624x480 / visible618x480 probe assumption has been removed.
Historical installation/stream results do not qualify these new profiles.

## Contract and selection API

`assets/plex-profiles/fpga_profile.hpp` supplies the request-side helper:

```cpp
misterplex::FpgaPmsProfile profile;
std::string why;
bool ok = misterplex::selectFpgaPmsProfile(
    "ip", "240p", 24000, 1001, false, profile, &why);
```

Arguments are prototype (`idr`/`ip`), decoded-picture mode, **exact content**
rate numerator/denominator, filtering-off boolean, output, optional error,
and optional `allowReservedExperiment=false`. Failure clears the output.
This helper describes an experimental encoder contract, **not** a
core/daemon capability handshake and not permission to advertise playback.

| Property | Both prototypes | Difference |
|---|---|---|
| Active decoded cap | coded and cropped visible dimensions ≤320x240 | Aspect-preserving smaller pictures permitted, not full-size tier proof |
| Content rates |24/1 and24000/1001 | Output60/59.94 timing is a different property |
| Profile / pixels | H.264 Baseline66 with constraint_set1=1, CAVLC, progressive8-bit4:2:0, level≤30 | Never CABAC, B, interlaced-coded, or 8x8 transform |
| Reference use | No weighted-P, reference-list modification, long-term/adaptive marking, or reordering | I/P: max references1; all-IDR: SPS0 **or**1 is legal |
| Intra modes | I4 all9 modes, I16 all4 modes, chroma all4 | Intra-in-P included; I_PCM forbidden |
| Inter modes | P16x16 and Pskip only | No16x8,8x16,8x8/sub-MB partitions |
| POC | Types0 and2 parsed/characterized | Type1 explicitly unsupported |
| VUI syntax | Timing/SAR/colour/restrictions parsed, reordering0 | HRD and pic_struct signaling rejected to match supported FPGA syntax |
| GOP | scenecut0, closed GOP, no intra-refresh | all-IDR keyint1; I/P keyint24 |
| Slices | One complete slice/picture, threads1, no slice groups | All MBs and residuals walked; truncated final slice fails |
| QP / residual | MB QP10..40, legal QP deltas, signed16 coefficients; no silent saturation | Actual QP/CBP/level/mode distributions reported |
| Filtering | Separate `filter-on` and `filter-off` profiles | On requires emitted idc0/offsets0; off requires emitted idc1 |
| Encoder bounds | libx264 software, VBV4000kbit/s,1000kbit buffer, AU≤262048bytes | Shared-ABI transport ceiling only; measured peak/headroom and actual core/RBSP cap still govern |
| Audio/container | HTTP MPEG-TS, H.264+AAC, stereo target | One A/V stream; qualification does not test A/V synchronization |

**Important measured encoder behavior:** a local x264 fixture with
`partitions=none` still emitted I4, alongside I16. The option is not an
I16-only guarantee. The syntax gate counts actual MBs and supports all listed
intra modes. FPGA support for each mode still needs independent pixel proof.

Neither prototype is an I16-only capability. Negotiated `Intra` must cover the
required I4/I16/chroma modes, including real residual reconstruction, not just
SPS parsing, MB0, or one narrow donor fixture. `Color420` requires reconstructed
U/V, not constant chroma or consumed syntax; `H264Decode` is not an input-header
parser capability. Default filter-on additionally requires genuine filtering
support. The ARM admission gate may inspect headers without walking/decoding MB
data; it must rely on truthful FPGA capabilities and fail closed when those
capabilities are absent. A profile syntax pass must never manufacture these bits.

The current262048-byte **physical transport** AU ceiling is
`262144 ring −32 header −32 metadata −32 reserved Resume/control`. The earlier
262080 ceiling did not reserve that final control record. The helper now reads
`ddr_bitstream_ring::kMaxAccessUnitBytes` directly, and Python obtains the same
compiled value through `--probe-contract`, avoiding duplicated stale constants.
ARM must use **min(shared ABI ceiling, freshly advertised encoded-AU capacity)**, never assume
the whole transport ceiling is decoder-owned storage. Pass that smaller limit
to the experiment with `--max-au-bytes N`; both probe layers reject larger
limits. A requested1000kbit VBV buffer is not proof of actual encoder behavior.
The report records observed AU peak and remaining bytes/fraction for the selected
limit. A final release AU limit remains **unselected** until representative real
PMS maxima, burst/headroom requirements, and actual core storage are measured.

The source owner verified the active320×240 instance sets `MAX_AU_BYTES=8192`,
with a separate8192-byte VCL RBSP capacity; its feature flags remain0.
The encoded-AU limit excludes transport metadata but includes every Annex-B NAL
in that AU. This is **different from** the262048-byte
physical ring upper bound and its full-ring transport bench. Production must use
fresh `caps.max_au_bytes`, not the helper's physical ceiling or an old design
default. Frontend capacity changes must be proven separately. Every sample
evaluated for this decoder must pass the8192-byte whole-AU and VCL RBSP checks;
title139/key36 I/P fail, while synthetic-source145 I/P passes these observed
byte bounds. Use `--max-au-bytes 8192`, or set
`MISTERPLEX_BASELINE_MAX_AU_BYTES=8192` for the live wrapper. Without an explicit
consumer limit the report says `au_limit_source=transport-ceiling-only`; that
mode is transport characterization, never hardware admission. Even a supplied
limit does not query or certify a live core: `hardware_compatibility_checked=false`.

Keep a **third, independent bound** for the decoder's VCL RBSP RAM. Use
`--max-vcl-rbsp-bytes 8192` (or wrapper environment
`MISTERPLEX_BASELINE_MAX_VCL_RBSP_BYTES=8192`) to reproduce the8192-byte RAM check;
use a different value only from verified actual frontend storage.
This counts each VCL NAL payload after emulation-prevention removal, excluding
the NAL header/start code and conservatively retaining delivered trailing padding.
It is not the aggregate encoded AU, which can also contain SPS/PPS/SEI/AUD NALs.
The report distinguishes encoded AU maximum, escaped VCL NAL maximum, de-escaped
VCL maximum, and selected limits/margins. A valid filler/metadata-heavy AU may
exceed8192 while its VCL RBSP fits; regression tests prove these limits are not
interchanged. Production must enforce both the negotiated encoded-AU capacity
and verified VCL storage, without assuming either proves decoder capability.

480i/480p both reserve a progressive decoded640x480 cap;720p reserves1280x720.
The helper rejects these by default. No larger-mode XMLs are generated or
installed, and the live harness refuses them. An explicit offline
`--reserved-experiment --mode 480p|480i|720p` analyzes larger captures without
advertising support. `--require-full-size` requires both coded and visible
dimensions exactly equal to that tier; a small upscaled decode cannot pass.
SPS crop and SAR are reported separately from output raster/DAR.

### Actual picture geometry is not the tier maximum

The320x240 tier is a **maximum coded rectangle**, not a demand that every movie
contain300 MBs. The probe accepts legal shorter/narrower pictures inside that
bound and emits authoritative SPS geometry in `syntax.json.geometry[]` and
`measurement.json.sps_geometry[]`:

* coded/visible width and height, MB columns/rows, expected MBs per picture;
* crop offsets in pixels, counted pictures using each SPS, explicit SAR-known/
  signaled flags, and reduced bitstream DAR **only when SAR is actually known**;
* a labelled `packed_i420` reference layout: plane strides, offsets, and bytes.

H.264 does not signal memory stride. `packed_i420` is a packed reference layout,
**not an assertion about FPGA DDR packing**. A controller/presentation descriptor
must carry its real storage strides, which may include alignment padding. Neither
the maximum tier width nor cropped visible width is an implicit storage stride.

For measured title139, the coded rectangle320x224 requires20×14=**280 MBs**,
not300. Decode all coded rows before applying the bottom12-pixel crop to display
320x212. A packed reference uses Y/UV strides320/160, U/V offsets71680/89600,
and107520bytes. Source139's authoritative traces set
`aspect_ratio_info_present_flag=0`: **SAR and bitstream DAR are unspecified**.
Earlier probe versions printed an assumed SAR1/1; that was not an emitted value.
The current schema returns SAR0/0 with `sar_known=false` and null bitstream DAR.
It separately preserves source metadata DAR1.66 instead of manufacturing DAR
from the320/212 pixel rectangle.

Controller completion, reference promotion, and presentation must use actual
coded MB columns/rows, crop, layout strides, and preserved source DAR. Do not wait
for300 MBs on a280-MB picture, stretch to the tier rectangle, or add host
letterboxing to hide an unsupported layout. An exact-geometry-only decoder or
oracle must fail explicitly and remain unqualified for that aspect case.
`--require-full-size` remains a separate gate and rejects shorter/cropped pictures;
source145 now supplies full320x240 real-PMS input, but byte eligibility is not
FPGA tier qualification.

Regressions cover320x192 (240 MBs), coded304x224/visible300x212 (266 MBs and
304/152 packed strides), anamorphic SAR4/3→DAR16/9, and unspecified SAR without
an invented DAR. These are offline geometry checks, not hardware presentation proof.

### Fixed limited-range BT.601 scanout policy

The new320 FPGA scanout currently uses fixed limited-range BT.601 conversion,
not dynamic SPS range/matrix selection. The probe records video-signal presence,
`full_range_flag`, color-description presence, primaries, transfer characteristics,
and matrix coefficients in each SPS geometry record's `color` object.

Known full-range signaling (`full_range_flag=1`) and known non-BT.601 matrices
(including BT.709 `matrix_coefficients=1`) return nonzero. Matrices5/6 are the
BT.601-family coefficients accepted by this fixed conversion. Unknown matrix2
is **legal unspecified syntax** and remains accepted for bounded byte/syntax
characterization. It is not promoted to signaled BT.601 because the picture is
small or a frame-store corner test passes.

For the explicitly unqualified first-IDR engineering bring-up, the coordinator
permits the controller's documented **matrix2→limited-BT.601 rendering default**,
applied consistently through native scanout. This is a surfaced rendering
assumption, not a change to source signaling or a color-qualification result.
The probe reports that limited scope, retains `matrix_coefficients=2`, keeps
`limited_bt601_signaling_ok=false`, and performs no RGB conversion. Do not turn
the optional strict assessment into an unrelated blanket rejection of legal
unspecified-matrix byte decoding.

Use `--require-limited-bt601`, or
`MISTERPLEX_BASELINE_REQUIRE_LIMITED_BT601=1` with the live wrapper, for the
fixed-scanout signaling eligibility gate. This also rejects an unspecified
matrix. The report separates `syntax_ok`, `probe_contract_ok`, and
`limited_bt601_signaling_ok`; valid CAVLC syntax/raw-YUV decoding may coexist
with a nonzero color-policy result. Neither signaling compatibility nor this
gate advertises or proves FPGA `Color420`. Final240p release still requires
correct per-stream matrix/range handling and matching glass; the bring-up default
does not relax that requirement or the known-unsupported fail-closed policy.

All four actual title139 streams set `video_signal_type_present_flag=0`.
Their range flag is absent and inferred0 under H.264 defaults; color-description
fields are absent and matrix defaults to2, **unspecified**. Thus no explicit
full-range/BT.709 violation was measured, but BT.601 scanout eligibility remains
unproven. Strict offline checks return1 for all four unchanged streams, with
complete syntax results retained in `build/pms-limited-bt601-assessment/`.
These checks do not alter the original acquisition or decoding hashes.

Do not “fix” missing/incompatible color signaling by rewriting an emitted SPS,
adding labels to unconverted pixels, or doing ARM video conversion. Any later
PMS-side conversion experiment must actually convert range/matrix during server
encoding and verify the resulting pixels and signaling. No profile XML color
override was added. This work was initially deferred; the later operator-owned
RGB601 source146 and its actual PMS outputs establish the measured matrix/range
result below without retagging delivered bytes.
Regression positives use generated RGB converted to limited BT.601 before
encoding, with separate real-conversion full-range/BT.709 negative fixtures.

### Exact names

The eight active experiments have names:

```text
MiSTerPlex-FPGA-{IDR,IP}-240p-{24,23976}-{filter-on,filter-off}
```

`generate_profiles.py` deterministically generates these eight XML assets.
There are no broad DirectPlay profiles. Even original H.264 sources must be
transcoded for the experiment; “already H.264” is not compatibility proof.

### ARM resolver integration

Use the helper's `clientProfileName` on **both decision and start requests**:

```text
X-Plex-Client-Profile-Name: MiSTerPlex-FPGA-IP-240p-23976-filter-on
```

Use a unique session/client identifier for the experiment and keep the same
identity for its decision, start, and stop. Token stays in an authenticated
header using the existing secret-safe mechanism, never a URL, log, or argv.
Do not send `X-Plex-Client-Profile-Extra`/legacy capability overrides for this
profile family: they can interfere with server-side constraints.

Required universal request parameters:

```text
hasMDE=1
path=/library/metadata/<LOCAL_KEY>
mediaIndex=0
partIndex=0
protocol=http
container=mpegts
directPlay=0
directStream=0
directStreamAudio=0
location=lan
copyts=1
session=<UNIQUE_SESSION>
offset=<SECONDS>
videoResolution=320x240
videoCodec=h264
audioCodec=aac
audioChannels=2
maxVideoBitrate=4000
videoQuality=60
videoProfile=baseline
videoLevel=30
videoFrameRate=24 or 24000/1001
```

For eligible subtitles add `subtitles=burn`, `subtitleStreamID=<LOCAL_STREAM_ID>`,
and `subtitleSize=100`. Passing this request does **not** prove the subtitle
appeared; inspect captured picture output against the source/selected subtitle.
The probe records requested subtitle ID and source stream metadata.

Do not implement fallback from an unsupported prototype to a software video
player. The ARM owner wires requests and rejects unsupported actual streams.
The profile helper deliberately does not include/change shared AU or ABI types.

## Persistent installation (sole lab operator)

Install only `MiSTerPlex-FPGA-*.xml` into the PMS **data-directory** `Profiles`
subdirectory. Never replace `Generic.xml`, Chrome/Web defaults, or shipped
resource profiles. Do not change global hardware-transcoder preferences.

The previously documented lab mapping is:

```text
host: /home/flynnsbit/plex/config/Library/Application Support/Plex Media Server/Profiles
container: /config/Library/Application Support/Plex Media Server/Profiles
```

The operator must confirm the live PMS data-volume mapping first. An example
for that confirmed host mapping, from the integration checkout:

```bash
PROFILE_DIR="/home/flynnsbit/plex/config/Library/Application Support/Plex Media Server/Profiles"
install -d "$PROFILE_DIR"
for profile in assets/plex-profiles/MiSTerPlex-FPGA-*.xml; do
  install -m 0644 "$profile" "$PROFILE_DIR/"
done
```

On2026-09-05 the sole lab operator reported all eight **initial-revision** XMLs installed
with exclusive no-overwrite writes and byte/SHA256 verification at that confirmed
data-volume path. Existing global-profile bytes were unchanged; sessions were
zero before installation, and no PMS restart was performed. The operator's
manifest is `Memory/lab/p0-lab-20260905/pms-profile-install.json` in the primary
lab store. PMS1.43.3.10828 remained reachable with the expected machine identity.
Those installed files requested VBV4000k/4000k, **not** the later source revision's
4000k/1000k. A subsequent live capture established that initial profile loaded
without a restart. The operator subsequently backed up that revision and updated
only the eight owned files to4000k/1000k. PMS cached the old encoder settings, so
the operator restarted **only** the identified `plex` container once, after both
playback and transcode session checks returned zero, and rechecked server identity.
The four24fps cases below confirm emitted `vbv_bufsize=1000` after that reload.
No other clients' profile files were changed.

PMS generally loads profiles at startup. If activation requires restart, only
the sole lab operator restarts the identified PMS instance in a safe window:
that disconnects other active streams. Do not silently restart an unrelated
server/container. Rollback removes **only these eight unique filenames** from
the same confirmed directory, then reactivates PMS as necessary. Leave
`MiSTerPlex.xml` and other clients alone.

These profiles explicitly request `libx264` and x264-specific flags. A PMS
build/hardware encoder may ignore or reject them, or silently use Generic.
That combination remains **unsupported/unqualified** when the actual byte
contract fails. The harness records available transcode-session hardware
telemetry and requires an x264 SEI signature; it does not prove a hardware
encoder's equivalence or alter global hardware settings. Hardware decode on
PMS and hardware **encode** are different operations.

## Bounded live qualification

Run only through the lab operator. The wrapper reads existing
`MISTERPLEX_CONF`/`MISTER_CONF`, `assets/misterplex.conf`, or the user's existing
MiSTerPlex config, with environment overrides. Never put a live token in the
command below; the secret-safe local launcher supplies authentication.

```bash
make "$PWD/build/pms_baseline_probe"
PLEX_BASE=http://192.168.1.24:32400 \
MISTERPLEX_BASELINE_KEY=/library/metadata/139 \
tests/hw/test_pms_baseline_profile.sh \
  --prototype ip --fps 24 --filter on --seconds 8 \
  --max-au-bytes 8192 --max-vcl-rbsp-bytes 8192 \
  --output build/pms-real-ip-24-on
```

The measured title139 I/P stream is expected to fail this8192-byte
consumer limit. That nonzero result is required, not a reason to silently widen
the advertised capacity, split an AU, drop bytes, or fall back to ARM video.
Use the physical transport ceiling only for an explicitly labelled transport
experiment, never to override the smaller downstream capacity.

Repeat with `--prototype idr`, each filter policy, and `--fps 24000/1001` on
appropriate source material. The source Stream frame-rate metadata must match
the selected rational; unknown/mismatched source rates fail native-film
qualification. A separately labelled `--allow-rate-conversion` experiment
permits conversion testing without claiming native film-rate source coverage.
Output must be a **new or empty project-relative
directory**; existing evidence is never overwritten. No temporary directories,
token files, interactive prompts, global mutations, or pass-stamp promotion.
Each attempt owns/stops only its UUID transcode session. Missing prerequisites
return77 with `SKIP-NOT-PASS`. Every unsupported stream returns nonzero.
Capture limits:4..30 seconds requested,64MiB ingress,120-second ingress wall
limit plus bounded metadata/demux/analyzer timeouts.
Streaming reads use available partial data, not a fill-oriented32KiB read,
and promptly flush delivered bytes to the demuxer. The streaming open/read
timeout defaults to30 seconds; select1..60 with `--stream-read-timeout` or
`MISTERPLEX_BASELINE_STREAM_READ_TIMEOUT`. Each read is additionally limited
by the remaining ingress deadline. The POSIX harness also arms an independent
wall-time alarm, so trickled chunk framing or a blocked demux pipe cannot reset
that deadline. No automatic retry is performed.
Decision/stream/demux failures retain a secret-safe `failure-result.json`
with the stage, exception type, received/preserved MPEG-TS body bytes, limits, and
own-session stop-request outcome. A successful stop request is **not** an
independent verification that the session disappeared. Incomplete capture is
not an emitted-codec/profile rejection and does not run syntax qualification.
Offline loopback regressions retain a complete96-frame synthetic transport and
cover small partial HTTP bodies, chunked bodies, prematurely closed bodies,
no first body byte, an invalid HTTP status containing a synthetic secret, and
trickled chunk framing that never completes a read despite continual traffic.
Before any live request, the harness verifies its compiled probe protocol using
`--probe-contract` (probe protocol6, distinct from the device ABI); a stale binary
now fails before capture. Frozen run directories
bind the Python harness, rebuilt probe, XMLs, and dependency sources through a
SHA256 manifest. Preserve that manifest with capture provenance.

Local identity previously reported:
`bf36a3ad8d4f6810ab3f69ec9f1adb22a7a9dc8a`.
Rating139 is the local B6 RealGlass720x48024fps title.
Rating143 is Grid720 **30fps**, so it is not native film-rate source evidence.
Old remote key40868 must not be substituted for a local key.

### Explicit missing-source fixture (operator import only)

The operator's pre-import inventory of PMS1.43.3.10828 found all144 library
videos were H.264; source139 has no subtitle stream. The subsequently imported
synthetic source below supplies non-H.264 mechanics coverage, not a movie sample.

The proposed conditional additive test-fixture scope is exactly one uniquely named item in
an isolated `MiSTerPlex_P1_30ff2997` child directory of the existing MiSTerPlex Tests
library. The earlier authorization gap was subsequently resolved **for this exact
fixture only**: the sole operator copied it atomically and requested a scoped
Section2 refresh. This does not authorize other imports or mutations; existing media and global PMS
defaults must remain unchanged. This16-second **synthetic source** is not a
replacement Plex output:

```bash
mkdir -p build/pms-profile-inputs
ffmpeg -v error \
  -f lavfi -i 'testsrc2=size=640x480:rate=24000/1001' \
  -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
  -f srt -i assets/plex-profiles/qualification-subtitle.srt \
  -map 0:v:0 -map 1:a:0 -map 2:s:0 -t 16 \
  -c:v mpeg2video -q:v 4 -g 24 -bf 2 -pix_fmt yuv420p \
  -c:a aac -ac 2 -b:a 128k -c:s srt \
  -metadata title=MiSTerPlex_P1_MPEG2_23976_Subtitle_30ff2997 \
  -metadata:s:s:0 language=eng -disposition:s:0 0 -n \
  build/pms-profile-inputs/MiSTerPlex_P1_MPEG2_23976_Subtitle_30ff2997.mkv
```

The requested file already exists and was verified without overwriting it:
SHA256`d70ca192e49966a36d8c5b73572e03621a8840c8531d6d2594843f4721b2dd61`,
5990169bytes,16.021seconds; MPEG-2 video640x480, SAR1:1/DAR4:3,24000/1001,
AAC48kHz stereo, and SubRip. Reuse that exact verified file instead of generating
another version or modifying an existing library title.

After explicit coordinator authorization, only the operator may copy that exact new filename into the **confirmed**
MiSTerPlex Tests library directory and request a scan scoped to that directory.
Do not create a new library, overwrite an item, install codecs, or modify global
settings. Refuse an existing destination with a different hash; reuse an
already-imported identical item rather than duplicating it.
An initial targeted search found no exact fixture match. After the subsequently
authorized import, the indexed local item is **ratingKey145, SRT StreamID290**.
Its confirmed host directory is
`/home/flynnsbit/plex/media/movies/MiSTerPlex_P1_30ff2997/`, mapped to
`/data/movies/MiSTerPlex_P1_30ff2997/` in the container.
No library creation, global/profile setting change, or PMS restart was involved.
Reuse the indexed item rather than importing another copy.
The completed campaign used `--fps 24000/1001`, first without and then with
`--subtitle-stream-id 290`; see its failed burn result below.
Keep output directories distinct. Verify the first caption in default-decoded
captured video at2..6 seconds; a burn request alone is not visual evidence.
Label these results **synthetic MPEG-2 source / real-PMS output**. They cover
codec/rate/subtitle mechanics, not representative non-H.264 movie quality.

Artifacts:

* `delivered-network.ts`: raw authenticated response body (no headers/secrets),
  including bounded demux read-ahead. Its tail can end between packets.
  `network-packets.json` preserves original server framePTS; the first captured
  picture window must match remux cadence exactly.
* `delivered.ts`, `delivered.264`: bounded complete-picture server video; remux
  only, no encode or bitstream flag rewrites. Any constant PTS rebase is reported.
* `source.json`, `encoder-session.json`: whitelisted source and encoder
  telemetry; never raw authenticated responses.
* `syntax.log`, `syntax.json`: every accepted SPS/PPS, slices, GOP, MB types/
  prediction modes, CBP, residual coefficient/block counts and level extrema,
  MB/slice QP, motion-vector differences, deblock policy, geometry/crop/SAR,
  coded AU maxima. Replacing an SPS/PPS under the same ID is explicitly rejected
  pending a separately qualified stream epoch.
* `packets.json`: per-video-AU PTS/DTS/duration/size and stream metadata.
* `headers.trace`: independent FFmpeg `trace_headers` of SPS/PPS/slices.
* `default-decoder.framemd5`: ordinary independent video decode hashes. No
  `skip_loop_filter`, oracle filter suppression, or flag modification.
* `measurement.json`: TS/H264 SHA256, packet rate, framePTS deltas, bitrate,
  peak1-second bitrate, observed maxAU/headroom under the selected core/transport
  ceiling, separate VCL NAL/RBSP maxima and RAM-limit margins,
  conservative4000k/1000k VBV-token-bucket gate, reported x264 options, and
  explicit range/matrix-signaling eligibility distinct from syntax completion.
  A reported old VBV/QP configuration is a revision mismatch even when the short
  observed sample fits the new bounds. SEI options supplement, never replace,
  inspection of actual SPS/PPS/slices and observed bytes.

24fps at90kHz must have3750-tick deltas.24000/1001 must have3753/3754 ticks,
with cumulative error≤one tick; PTS and DTS must agree. Merely accepting an
FPS argument, reading nominal SPS timing, or counting USB refreshes cannot pass.
The probe requires at least48 complete video pictures and agrees the syntax
picture count with demuxed packet/AU count.

Offline analysis uses `--input-ts PATH`; reports are explicitly marked
`origin=offline-container`, never real-PMS evidence.
The C++ `--annexb` interface is a **syntax-only** gate and explicitly reports
that timing, PMS origin, independent decode, and FPGA/glass proof remain separate.

## First real-PMS measurement: initial IP24/filter-on revision

The operator captured title139 through PMS without restarting the server.
Original artifacts are preserved at
`build/pms-real-ip-24-on-20260905T162556Z/` in the integration tree.

| Observation | Measured value |
|---|---|
| Source | H.264720x480, numeric24.000fps, metadata DAR1.66, AAC stereo; no subtitles |
| Actual output | Baseline66/level30, CAVLC, refs1, POC2, progressive4:2:0 |
| Geometry | **coded320x224, visible320x212**, bottom crop6×2 pixels; SAR not signaled (older probe assumed1/1) |
| Pictures/GOP |192 pictures /8s,8IDR +184P, GOP24, one slice/picture, no B |
| Original PTS |127920..844170 at1/90000; every delta3750, no remux rebase |
| Bitrate / largest AU |430129bit/s average,17494bytes maximum |
| Transport headroom |Original report244586bytes below then262080;244554bytes below current262048; no release/core capacity selected |
| MBs |53760 total:11974I16,972I4,25447P16,15367skip; no PCM |
| Residual / QP |484263 nonzero coefficients,178876 nonzero blocks; levels−68..119; QP10..32 |
| Modes / motion |All9I4, all4I16, all4chroma modes observed; maximum absolute MVD924 |
| Filtering |All192 slice headers signal idc0; independent decoder filtering unchanged |
| Independent decode |192/192 pictures decoded successfully; hashes retained |
| Encoder revision |x264 reported VBV4000/4000, keyint24, B0, ref1, CAVLC, QP10..40, slices1 |
| Original H264 SHA256 |`95aa37cd05c6e9c54582212a8547fcb8e4666f97e1f905d371c1f5b261327976` |
| Original TS SHA256 |`ea3a7eaa5f7beaf2fafa1b4cf95feb4d0bbe60709c4f316210eb2119981c350b` |

The original invocation's `syntax_ok=false` was **a tooling failure**: a newer
Python command called an older binary, which printed CLI usage. It was not an
H.264 rejection. Reanalysis using the coherent frozen-v1 probe walked every MB
and residual successfully; its separate report is
`build/pms-real-ip-reanalysis-v1/syntax.log`. Original artifacts were not changed.

This first run characterizes the **initial** IP/filter-on revision. The following
campaign supersedes its encoder-revision coverage without altering its evidence.

## Real-PMS comparison: both24fps prototypes and filtering policies

The sole operator completed four coherent frozen-harness runs after the deliberate
profile reload. Original provenance and results reside in the primary lab store:

```text
Memory/lab/p0-lab-20260905/profile-campaign-20260905T163239Z/
  input-manifest.json
  oracle-handoff.json
  live-results-reloaded.json
  build/real-pms-{ip,idr}-24-filter-{on,off}-reloaded/
```

The original four-case `oracle-handoff.json` bound44 per-case artifact sizes/
SHA256 values plus the frozen input-manifest identity; those bindings were
independently verified. The later key36 attempt extends that handoff separately.
Its absolute root is the primary `MisterPlex/Memory` symlink target under
`lab-monorepo/projects/misterplex/memory`, not the separate `~/Projects/Memory`.
For ordinary comparison use bounded `delivered.264` and its matching192-picture
`default-decoder.framemd5`, not extra read-ahead pictures from
`delivered-network.ts`. Preserve the encoded filtering policy. Cropped visible
output and the full coded/reference surface remain distinct comparison domains.
For the original title139 cases, the handoff's older `SAR1` note preserves the
original probe assumption; actual traces and corrected geometry report SAR
unspecified. This must not be generalized to later streams that explicitly
signal SAR, such as key36 below.

All four runs emitted192 complete pictures over8 seconds with original3750-tick
PTS increments at90kHz, no reordering, Baseline66/CAVLC/POC2, and one slice
per picture. Actual SPS `max_num_ref_frames` is **1 for I/P and0 for all-IDR**;
the encoder's reported `ref=1` setting must not be mistaken for the emitted
all-IDR SPS value. Every run passed complete MB/residual syntax inspection and
ordinary independent decoding192/192. Actual x264 options report software
encoding, no B/weighted-P/8x8 transform, VBV4000k/1000k, and QP10..40.
Independent traces show constraint_set1=1; both HRD flags, pic_struct, bottom-POC,
weighted prediction, constrained-intra, reorder count, and chroma QP offset are0.
Filter-on slice offsets are0; filtering-off correctly omits those offsets.

| Prototype | Emitted filter idc | Bitrate(bit/s) | Largest AU(bytes) | IDR/P | GOP maximum | Actual QP | Coefficient range |
|---|---:|---:|---:|---|---:|---|---|
| I/P, on |0|430129|17494|8/184|24|10..32|−68..119|
| I/P, off |1|429625|17494|8/184|24|10..32|−68..119|
| All-IDR, on |0|589909|4979|192/0|1|10..40|−56..88|
| All-IDR, off |1|589909|4979|192/0|1|10..40|−56..88|

The I/P on run contains11974I16,972I4,25447P16,15367skip MBs; off contains
11733I16,972I4,25233P16,15822skip. Each all-IDR run contains37917I16 and15843I4,
with normally compressed residuals and no PCM. All runs total53760 MBs.
The encoder reports `keyint_min=13` for the requested I/P GOP24: its normal
minimum-keyint clamp is not an exact minimum24 guarantee. Actual observed GOP
maximum24 and scenecut0 satisfy this bounded I/P experiment.

Every output remains **coded320x224, visible320x212**, not full320x240.
SAR is not signaled; the visible pixel ratio≈1.509 is **not** an encoded DAR.
Source metadata DAR1.66 must remain separate and its preservation through actual
presentation must be verified. A default assumption of square pixels is not
evidence of a source-DAR mismatch or a valid reason to stretch/letterbox on the host.
No re-encoding or dimension manipulation was used to make this a full-sized tier.

| H264 stream | SHA256 |
|---|---|
| I/P on |`fb316113fe65cda8bc42345edc1c33579e0618b095c64be55fc53dff42ba12ba`|
| I/P off |`095ef5c116ee6841adc5854e9c9b01c8bfe5475ad2eea97edebe74c3d6173591`|
| All-IDR on |`e3bebad8ad499e31a03b5b0d8f702e51f6596b065467e10047b2e4187b5c4b04`|
| All-IDR off |`5a674c69ede1fb3781a959fcccb257012b52fefe935e69341e3760d366583694`|

The operator later repeated these four real-PMS cases using the exact frozen-v2
bundle (`SOURCE_MANIFEST.json` SHA256
`7efed19ca7587f7a479b20241ece81c5bce8c06471ee085a6339a75e6c7f06fa`).
`build/pms-profile-frozen-30ff2997-v2/build/live-v2-results.json` records all four
exit0 results, actual VBV4000/1000, and their independent measurement/syntax/
elementary-stream identities. Its12 artifact hashes were verified; each H264
hash exactly matches the corresponding original campaign stream above.
The eight installed profiles already matched, so this repetition involved no
profile-file overwrite or PMS restart. It confirms that frozen bundle's served
revision and repeatability, not additional source/rate/capacity or hardware coverage.

Original campaign reports used the then262080-byte ceiling. Frozen-v3 offline
reanalysis independently passed all four **unchanged** H264/TS identities with
the current shared-ABI262048-byte cap, encoder-option checks, and default decoder.
Those reports are in the integration tree at
`build/pms-profile-frozen-30ff2997-v3/build/reanalyzed-real-{ip,idr}-24-{on,off}/`,
with `real-pms-reanalysis-summary.json` alongside. Their `origin=offline-container`
describes the reanalysis operation; real-PMS acquisition provenance remains in
the original operator campaign. Headroom at the current cap is244554bytes for
I/P and257069bytes for all-IDR.

A subsequent real-PMS attempt with the old frozen-v3 harness **failed**:
`build/pms-profile-frozen-30ff2997-v3/build/live-139-ip-24-on-001/`.
Metadata, decision, start response and MPEG-TS MIME succeeded, but the initial
fill-oriented32768-byte read timed out after10 seconds. Both `capture.log`
and `delivered-network.ts` remained empty; there is no measurement or syntax
result for that attempt. The operator preserved `failure-result.json` and
verified session counts returned to zero. This is a capture/transport failure,
not a profile rejection, and does not replace the successful v2 corpus or
v3 offline reanalysis. At that point the partial-read/timeout hardening was
offline-only. The later authorized RGB601 pair used frozen-v7 containing it;
the original v3 timeout is still retained as a failure, not relabeled a success.

A separate unchanged-byte reanalysis against the current reader's8192-byte
budget is retained at `build/pms-reader-8192/summary.json` and per-case reports:

| Prototype/filter | Result at8192 | Observed largest AU | Budget margin |
|---|---|---:|---:|
| I/P on/off |FAIL, `au-byte-limit`|17494|−9302bytes|
| All-IDR on/off |Fits observed byte budget only|4979|3213bytes|

The two I/P invocations return1 while ordinary independent decoding still
succeeds. The report explicitly identifies a byte-limit compatibility rejection,
not malformed H.264. Its bounded parser stops at that limit; full syntax
characterization remains in the earlier complete reports. All-IDR fitting this
short sample does not prove worst-case headroom, complete Intra/color/filter
hardware support, or a winning release prototype.

The I/P peak also exceeds16KiB: encoded AU is1110bytes over16384, and VCL RBSP
is1065bytes over16384. At a **conditional**65536-byte envelope those observed
maxima leave48042 and48087bytes respectively. This arithmetic is not evidence
that the running core has64KiB buffers or implements their complete ownership,
cursor, completion, and reset contracts. Fresh advertised capabilities and
actual storage must bound admission.

An independent RAM-specific comparison allowed the physical AU envelope262048
but separately enforced VCL RBSP8192; results are at
`build/pms-vcl-rbsp-8192/summary.json`. I/P on/off has escaped VCL NAL maximum17450
bytes (excluding start code), de-escaped payload17449, and fails the RAM limit by
9257bytes. All-IDR on/off has escaped VCL maximum4934 and de-escaped payload4933,
leaving3259bytes of observed RAM margin. These differ from the aggregate AU
sizes/margins above. Both I/P cases correctly remain nonzero even when the full
ring itself can hold their AUs.
The operator's hash-bound `current-capacity-assessment.json` alongside the
original campaign independently reports **5 of192 VCL payloads over8192 bytes
in each I/P variant**, versus zero in either all-IDR variant. Its EBSP lengths
exclude the NAL header; the probe's separately named VCL-NAL lengths include
that one header byte. The measurements agree after accounting for that
definition. Passing the earlier profile syntax/PTS/oracle checks does not
authorize publishing those five oversized payloads to an8192-byte frontend.

These are bounded profile experiments on one title, not a release decision.
Eight seconds of observed headroom does not establish worst-case AU behavior;
the actual core/RBSP capacity may be smaller. Quality, FPGA pixel agreement,
decode deadlines, sustained bitrate/thermal behavior, A/V synchronization, and
Web→glass playback remain unaccepted. The later source145 campaign adds
native23.976/full-size/synthetic non-H.264 coverage below, and source146 adds
visible burn mechanics. General selection and representative/aspect cases
remain open. Hardware-encoder
equivalence remains unqualified. The operator reported zero sessions after the
campaign and no token bytes found in the retained artifact scan.

The remaining campaign was initially deferred during connection recovery.
The coordinator subsequently authorized only the exact synthetic fixture and
the operator completed the bounded source145 cases below. That permission
does not authorize additional imports, global/default stream-preference changes,
or PMS restarts. Existing title139 cases remain complete and preserved.

## Full-size attempt: key36 remains red

A subsequent authorized key36 I/P/native24/filter-on capture tested
`--require-full-size` without altering output geometry. The expected result is
**exit1**: SPS coded320x240, but visible312x240 with right crop8pixels. Unlike
title139, its SPS explicitly signals SAR1:1 (`aspect_ratio_idc=1`), making the
delivered DAR13:10. Rounded source metadata `aspectRatio=1.33` was not proof of
an exact full4:3 delivered picture.

The operator subsequently probed the actual source files for **all four named
candidates36,37,38,40**, not just rounded PMS labels. Every source is H.264,
624×480, explicitly SAR1:1 and DAR13:10, at exact24/1; numeric PMS
`Stream.frameRate` is24.000. These are not exact4:3 source candidates, so blindly
capturing37/38/40 is not a replacement for missing full-size coverage.
The read-only source results are retained in the primary lab store at
`Memory/lab/p0-lab-20260905/named-fulltier-source-probes.json`.
These pre-import results record no library/profile mutation and, at that time,
no exact synthetic-fixture match.

The original directory is
`profile-campaign-20260905T163239Z/build/real-pms-ip-24-filter-on-key36-full320/`
under the same primary lab store. H264 SHA256:
`fae97cabbd2acf733c8cd71d244786b85dd80ee89070a6cc54f7898e787087fa`.
Original measurement SHA256:
`d50e8f580b808e56aeaf43bd696818027ce5250e3dd07aefea6da0f3dd9504c9`.
The original failure and ordinary192-picture decode are preserved.

Bounded, non-full-size syntax passes on the same bytes:192 pictures,8IDR/184P,
GOP24,20×15=300 coded MBs/picture (57600 total), all required intra modes,
QP10..31, coefficient range−89..111, original3750-tick PTS,364569bit/s.
Whole-AU peak17107 and VCL RBSP17061 exceed8KiB; even16KiB is insufficient.
Video-signal/color VUI is absent, so fixed-BT.601 signaling remains unproven.

Current-probe verification is retained at `build/pms-key36-assessment/`: bounded
geometry passes and the separate full-size gate explicitly reports
`coded=320x240 visible=312x240, required=320x240`. No crop flags, encoded bytes,
padding, or scaling were modified to manufacture a full-size pass. Key36 remains
a full-size failure; the subsequent synthetic source supplies a separate positive.

## Full-size/native23976 real-PMS capture: synthetic source145

The sole operator ran five own-UUID requests from frozen-v5
`SOURCE_MANIFEST.json` SHA256
`efab5ce412d539294a13a024303148b7a7e1ae9230ff94e0ee5beeb8fb8cce65`.
The integration-tree root is `build/pms-profile-frozen-30ff2997-v5/`;
`build/new-mpeg2-23976-handoff.json` gives exact case paths and all artifact
identities. All35 H264/TS/measurement/syntax/PTS/default-frameMD5 hashes were
independently checked. New current-probe reanalysis in
`build/pms-fullsize-23976-assessment/` passes the same unchanged bytes at both
8192-byte limits and `--require-full-size`.

All cases contain **191 actual pictures**, not192: coded and visible320×240,
20×15=300 MBs/picture, crop0, explicitly signaled SAR1:1/DAR4:3. Original90kHz
PTS alternate3753/3754 ticks at24000/1001; ordinary decoding completes191/191.
This is actual PMS output from synthetic MPEG-2/AAC/SubRip input, not a
representative film-quality sample. Packed-reference strides/offsets are not
evidence of the FPGA's physical layout.

| Prototype/filter | Whole-AU maximum / margin to8192 | VCL RBSP maximum / margin | Bitrate | QP | Actual PMS residual levels |
|---|---:|---:|---:|---|---|
| I/P on |7324 /868|7279 /913|445291bit/s|10..31|−315..834|
| I/P off |7324 /868|7279 /913|446710bit/s|10..31|−315..834|
| All-IDR on/off |7124 /1068|6398 /1794|586545bit/s|10..40|−228..607|

Those actual PMS coefficients exceed a signed9-bit range: retain the signed16
contract, never saturate them to fit an older decoder. Both prototypes fit the
observed byte budgets on this source; this does **not** erase the title139/key36
I/P capacity failures or prove worst-case release headroom.

| H264 case | SHA256 |
|---|---|
| I/P on |`be11d1d6847ea59d6f31f9d49b1e92853dd3c96ebdd689068137ca31ef3607d5`|
| I/P off |`b81bbe16369ba5d0905af0a47f21ea8027057e1e4fb8cbedada96b76cd07795e`|
| All-IDR on |`462d8973bed05f5f11e1e8a3e95bcd068c5c493b7ca9babd9aa52f0a82a9ece9`|
| All-IDR off |`e0f8c7fcc3ce16f7f17e8c98092f8cd33664c4fe50c59c7e79cd0377fd876670`|

Current color-aware parsing confirms all five streams again omit video-signal/
color-description VUI: range defaults to limited, matrix2 is unspecified.
Strict limited-BT.601 signaling remains false. The documented unqualified
matrix2 rendering default is not color certification. Features, full-stream
FPGA reconstruction, throughput, A/V, presentation and glass remain unqualified.

### Subtitle attempt: visually failed despite codec-only exit0

`build/new-mpeg2-23976-idr-on-sub/` requested actual SRT StreamID290. Its bounded
H264 and ordinary decoded-frame hashes are **identical** to the no-subtitle
IDR/on control. The operator verified the source cue at2..6 seconds and viewed
ordinary-decoded3s/5s PNGs: neither shows the expected caption.
`subtitle-visual-result.json` records this failure. The original frozen-v5
syntax/budget/PTS/default-decode gate's exit0 is retained honestly; it never
established visual subtitle burn. This does not establish that PMS generally
lacks subtitle support.

The current harness saves a sanitized `decision.json` and, when a subtitle ID
is requested, requires that exact stream's selection/burn to be confirmed by
the PMS decision before opening video. An unconfirmed decision returns1.
Default unscoped operation never writes preferences; the explicit new-fixture
exception below restores its temporary selection on failure. Even a confirmed decision
is not visual proof: expected caption pixels still require independent checking.
`--decision-only` performs the metadata/decision diagnostic without starting a
transcode stream; a confirmed diagnostic returns77 (`SKIP-NOT-PASS`), not a
qualification success.

The existing `subtitleStreamID` query is therefore an **unproven selection
mechanism**, not a supported per-session contract. The public
[transcode request documentation](https://github.com/LukasParke/plexpy/blob/main/docs/models/operations/starttranscodesessionrequest.md)
defines `subtitles=burn` as burning the **selected** subtitle, falling back
to automatic behavior when none is selected. The
[Python-PlexAPI selection helper](https://github.com/pkkid/python-plexapi/blob/master/plexapi/media.py)
instead changes `/library/parts/{id}` using PUT. That operation is not
session-scoped. The subsequent narrowly authorized opt-in below temporarily
sets/verifies/restores only the new lab fixture's exact Part; default operation
still performs no preference writes. No profile installation or PMS restart is requested.

The earlier diagnostic was frozen separately at
`build/pms-profile-frozen-30ff2997-v7/`, manifest SHA256
`fd1f0f4f34ba3bc79d1b5af36808dce95babb953c5461d7a69c8a9038640988d`.
Its24 members were checked; earlier bundles/results were not modified.
For a subsequent authorized operator diagnostic, reuse the existing secret-safe
launcher and run from that frozen root:

```bash
MISTERPLEX_BASELINE_KEY=/library/metadata/145 \
tests/hw/test_pms_baseline_profile.sh \
  --prototype idr --fps 24000/1001 --filter on \
  --subtitle-stream-id 290 --decision-only \
  --max-au-bytes 8192 --max-vcl-rbsp-bytes 8192 \
  --output build/decision-145-idr-23976-sub290
```

No live execution of that diagnostic is claimed here. Its unrun request is
superseded by the two-case authorization below, not an additional third attempt.

## Two-case23976 campaign preparation

Connection deferral was lifted **only for two bounded targeted PMS cases**:
all-IDR, encoder-signaled filter-off, native24000/1001, full coded/visible320×240
from an actual4:3 non-H.264 source, subtitles **off** then **on**. The sole lab
operator runs them. No repeated24fps acquisitions, live requests by this lane,
profile installation, PMS restart, or hardware action is authorized.

Preparation delivered immutable `build/pms-profile-frozen-30ff2997-v9/` and its
`SOURCE_MANIFEST.json`/`CAMPAIGN.json`. The completed execution below instead
used verified v7 with an external operator-owned selection/restore wrapper;
do not relabel those results v9 or repeat captures to change their provenance.
The implemented v9 single-case wrapper pins8 seconds,
30-second streaming timeout,120-second ingress deadline,64MiB ingress,
8192-byte whole-AU and separate8192-byte VCL RBSP bounds, full-size geometry,
and an actual `mpeg2video` source. It preserves the current color policy:
matrix2 is legal but unproven, not a strict limited-BT.601 signaling pass.
Known full-range/non-BT.601 matrices still fail. No retries or delivery-byte
retagging/re-encoding are performed. A failed case is retained, not repeated.

The operator independently prepared/imported exactly one new
RGB-to-limited601 MPEG2/AAC/SubRip fixture, preserving145. Use that source and
the operator's `Memory/lab/p0-lab-20260905/rgb601-campaign/import.json`;
do not create another fixture. Its actual local key/Part are146, SRT StreamID293,
and source SHA256 is
`a89d4437fe551ee6906c373e71068caa1e7610771c9c2dbf0920ebd22ab8631f`.
The earlier optional generator remains included
for reproducibility/offline tests, not an instruction to run it again:

```bash
bash assets/plex-profiles/create_color_fixture.sh
```

This creates a **new source**, never modifies delivered PMS video. Generated
full-range RGB is defined in SMPTE170M primaries/transfer and actually converted
to limited BT.601 YUV420 before MPEG-2 encoding and matching signaling.
That generator's16-second640×480 source is SAR1:1/DAR4:3 at24000/1001 with AAC stereo and
SubRip. Its SRT is marked default/forced **only inside this synthetic fixture**;
no PMS/user/library stream preference is changed. Those source flags do not
prove PMS selection: the burn decision and expected caption pixels still must
be observed. Existing files are never overwritten. The operator records its
hash/probe and performs only an authorized additive import/scoped scan if needed.

### New-fixture-only temporary subtitle selection

Session-scoped `subtitleStreamID` selection is still unproven. The coordinator
allows a minimal exception for this **new lab fixture only**, never global
defaults, older media, or145. Copy the fail-closed
`assets/plex-profiles/lab_fixture_scope.example.json` to an untracked campaign
output location and fill numeric `rating_key`, `part_id`, `subtitle_stream_id`,
exact `container_file`, and `source_sha256` from the operator-verified import.
Only then set `allow_temporary_part_subtitle_selection=true`. For the current
verified import, the bundle already supplies
`assets/plex-profiles/lab_fixture_scope_rgb601_30ff2997.json` with those exact
identities and container file; use it unchanged. The source hash is
import-attested, not silently claimed to be rehashed over PMS by this harness.

`--lab-fixture-scope FILE` binds the actual metadata key, single MPEG2 media
version, exact Part/file, and requested stream. It requires an RGB601 filename
and refuses known older captured/user keys, including139/145. OFF validates
the scope but makes no selection change. For ON it:

1. Records the original selected subtitle, or0 for none, in an atomically saved `subtitle-selection.json` before any PUT.
2. If necessary, sends only `PUT /library/parts/PART?subtitleStreamID=ID&allParts=0`, then verifies fresh metadata.
3. Requires the exact selected stream's burn decision before the one video start.
4. Stops its own transcode and restores the original selection on success or failure, then verifies fresh metadata again.

A PUT that errors after changing server state is still followed by restoration.
An unexpected concurrent selection is not overwritten. Unverified restoration
forces nonzero and leaves explicit recovery data; stop the campaign and have
the sole operator revalidate the Part/file and restore the recorded original
ID using the same scoped endpoint, not a global/default reset or capture retry.
This is a temporary **persistent per-Part preference**, not a session-local API.
If the desired stream was already selected, no PUT is made.
The recovery record also covers abrupt process/host death: restoration cannot
be guaranteed after a hard kill, so the operator must inspect/repair that exact
new Part before any continuation. There is no automatic capture retry.

Set `MISTERPLEX_LAB_FIXTURE_SCOPE` to that explicit scope file, alongside actual
`MISTERPLEX_BASELINE_KEY` and `MISTERPLEX_BASELINE_SUBTITLE_STREAM_ID`, and reuse
the secret-safe launcher:

```bash
export MISTERPLEX_BASELINE_KEY=/library/metadata/146
export MISTERPLEX_BASELINE_SUBTITLE_STREAM_ID=293
export MISTERPLEX_LAB_FIXTURE_SCOPE=assets/plex-profiles/lab_fixture_scope_rgb601_30ff2997.json
bash assets/plex-profiles/run_23976_campaign_case.sh off
bash assets/plex-profiles/run_23976_campaign_case.sh on
```

The off case explicitly sends `subtitles=none` and rejects a contradictory burn
decision. The on case requires that exact source stream's confirmed burn
decision before opening video. If it is unselected/unsupported after scoped selection, retain the
nonzero result and restore the recorded preference; do not retry.
Inspect ordinary decoded3s/5s pictures and the matching no-subtitle control;
exit0 from codec characterization alone never proves caption rendering.
PMS output geometry/rate/color/AU/RBSP must be assessed from its actual bytes,
even when the source was correctly converted/tagged. The bundle stays unchanged
through both cases. None of this is FPGA, color/glass, or playback acceptance.

## Completed RGB601 pair: actual v7 execution and visible burn

The operator completed exactly the two authorized captures using
`build/pms-profile-frozen-30ff2997-v7/`, manifest SHA256
`fd1f0f4f34ba3bc79d1b5af36808dce95babb953c5461d7a69c8a9038640988d`.
That bundle includes partial reads,30-second read timeout,120-second ingress
deadline,64MiB limit, exact geometry/color reporting and separate AU/RBSP gates.
The newPart146-only selection/verification/restoration was performed by the
operator's external wrapper. The v9 automatic restoration implementation
remains separately offline-exercised, not claimed as the live executor.

Canonical evidence is
`Memory/lab/p0-lab-20260905/rgb601-campaign/final-two-case-result.json`.
The case directories beneath the v7 root are
`build/rgb601-146-idr-23976-off-nosub/` and
`build/rgb601-146-idr-23976-off-sub293/`.
The v7 manifest and all24 capture artifact hashes were independently checked.
Current-probe strict reanalysis is retained separately in
`build/pms-rgb601-final-assessment/`; originals are unchanged.

| Property | Actual result in both cases |
|---|---|
| Pictures / rate |191 IDRs, no P/B, GOP1, native24000/1001 |
| SPS geometry |Coded/visible320×240; crop0;20×15=300MB/picture |
| Aspect |Explicit SAR1:1, decoded/source DAR4:3 |
| Color |Explicit limited range (`full_range_flag=0`), matrix6; primaries2/transfer2 unspecified |
| Reference/filter |SPS references0; encoded `disable_deblocking_filter_idc=1` |
| Whole-AU maximum |5801bytes;2391bytes observed margin to8192 |
| VCL RBSP maximum |5073bytes;3119bytes observed margin to8192 |
| Original PTS |131674..844886 at1/90000,3753/3754 steps; remux rebase0 |
| Ordinary decode / byte gates |191/191 frames; syntax, cadence, full-size, limited601 and both budgets pass |
| Residual levels |−607..228, still outside a signed9-bit range |
| QP / bitrate |OFF10..35 /587552bit/s; ON10..40 /587541bit/s |

The stored source's actual RGB-to-limited601 conversion was pixel-proven by
the operator before encoding and after stored-source decoding, including
black16, white235 and601 red/green/blue YUV values. Actual emitted H264 signaling
was measured independently; no delivered flags or pixels were rewritten.
Unspecified primaries/transfer were retained honestly, not retagged.

The OFF ordinary3s/5s pictures have no caption. ON3s/5s visibly show
`MiSTerPlex P1: subtitle burn-in`, with Stream293 selected/burn confirmed in
`decision.json`. Caption timing is2..6 seconds; the first12 frames are **not**
a subtitle test. Different full-stream hashes support, but do not replace,
the actual visual observation:

| Case | Bounded delivered H264 SHA256 |
|---|---|
| OFF |`80a3c9f49870955839d352144542c0ef887cde7ccb3c812bb9fff188d8bd9249`|
| ON |`bd3cb9dfc8290ce7daa6043689a57abdc712589c293324059672ad66943b4334`|

Use matching bounded `delivered.264`/`delivered.ts`, `packets.json` and ordinary
`default-decoder.framemd5`; read-ahead networkTS is retained for provenance/PTS,
not interchangeable with the191-frame bounded reference.
Original Part146 subtitle selection0 was restored and verified; normal and
transcode sessions returned to0, and the operator's token scan found0.
Old145, earlier failures, profile/global settings, server state and hardware
were not modified beyond the authorized new-fixture selection transaction.

This closes bounded synthetic-source full320/native23976/limited601 signaling
and visible PMS burn mechanics for this all-IDR/filter-off pair. It does not
prove movie quality, worst-case headroom, general subtitle selection, complete
FPGA reconstruction or throughput, A/V, native output, or LAN Web/glass playback.
No further capture is requested.

## Validation and remaining matrix

Targeted offline regression commands:

```bash
tests/unit/test_pms_baseline_gate.sh
tests/unit/test_pms_baseline_live_gate.sh
tests/unit/test_pms_nal_stats_gate.sh
```

They exercise all eight real compressed x264 fixture contracts, invalid
profile/CABAC/reference counts/partitions/GOP/rate/filter/geometry, reserved
caps, full-sized vs cropped pictures, late incompatible SPS, truncation, missing
live prerequisites, and token-safe failures. They do not qualify PMS.
Synthetic filler fixtures additionally test an AU exactly at the compiled shared
ceiling and reject both ceiling+1 and ceiling+32. These are transport-envelope
regressions, not encoder/VBV-positive samples; an old262080-style32-byte overrun
cannot pass the current262048-byte gate.

The NAL-statistics regression invokes the real command in `--annexb FILE`
offline mode. Overflow, malformed EOF, and a boolean consumer rejection during
either `push` or `finish` must return nonzero **even after a good NAL was
recorded**. Read errors and a nonzero FFmpeg child exit also invalidate the
measurement. Partial counts appear only in failure diagnostics; they cannot
produce successful statistics. Its optional `--max-nal-bytes` accepts a smaller
core limit (never above the shared ABI ceiling, currently262048); `--max-samples` bounds sample storage. Offline
read timing is not PMS arrival timing, and framing success alone does not
validate H.264 slice syntax or establish an AU/ring release limit.

The live acceptance matrix must cover both prototypes, both exact film rates,
both filtering experiments as applicable, original H.264 and non-H.264 sources,
full320x240 plus aspect/crop cases, subtitle-triggered transcoding, supported
software PMS versions, and explicit hardware-encoder limitations. Larger caps
remain reserved. Film source converted from30fps must be labelled conversion,
not native24/23.976 qualification.

Even a fully characterized real-PMS stream is only Phase1 input eligibility.
The decoder owner must match reconstructed Y/U/V against default independent
decoding of these exact bytes (including required filtering), then fit and
measure the real ingress/presentation path. Only the lab operator's LAN Plex
Web cast-picker → MiSTerPlex → real library play → matching live HDMI content
with Web playing can establish playback. No such claim is made by this document.
