# PMS profile for MiSTerPlex Baseline transcodes

Status: **installed and load-bearing on the lab PMS**. This file is now the
mechanism that makes PMS emit the Baseline/CAVLC stream the FPGA decoder is
scoped for. A Plex container rebuild, image upgrade, or config restore may
remove the profile; the symptom is delivery reverting to High/CABAC with
B-slices.

## Why this exists

Client-only requests are not enough on this PMS. The sweep in `build/misterplex-agent-W-A4.txt` found every working HTTP/mpegts variant delivered the same stream despite `videoProfile=baseline&videoLevel=30` and profile-extra limitations:

| Request family | Delivered result |
| --- | --- |
| URL params only | `profile_idc=100`, `cabac=1`, B=115/12s |
| `video.profile`/`video.level` profile-extra limitations | `profile_idc=100`, `cabac=1`, B=115/12s |
| `video.h264Profile`/`video.h264Level` match and notMatch forms | `profile_idc=100`, `cabac=1`, B=115/12s |
| Generic vs Chrome profile name | `profile_idc=100`, `cabac=1`, B=115/12s |
| `640x480`, `624x480`, and `width=640&height=480` | coded `624x480`, display `618x480` *(16:9 source; output insensitive to request — see §"PMS resolution sensitivity")* |

The prepared server-side profile is `assets/plex-profiles/MiSTerPlex.xml`. It constrains the HTTP streaming target to H.264/AAC in MPEG-TS and adds x264 flags for Baseline/CAVLC, no B-slices, one reference frame, weighted prediction off, no 8x8 DCT, no sub-macroblock partitions, and a bounded GOP.

## Client profile match

For universal transcode playback, `misterplexd` sends these client identity headers from `arm/misterplexd/plex_resolve.cpp`:

```text
X-Plex-Client-Identifier: misterplex
X-Plex-Product: Plex Web
X-Plex-Version: 4.125.0
X-Plex-Platform: Chrome
X-Plex-Platform-Version: 120.0
X-Plex-Device: Linux
X-Plex-Device-Name: Chrome
X-Plex-Client-Profile-Name: MiSTerPlex
X-Plex-Model: bundled
X-Plex-Provides: player
```

The PMS container's shipped profile resources show:

```text
/usr/lib/plexmediaserver/Resources/Profiles/Generic.xml: <Client name="Generic" />
/usr/lib/plexmediaserver/Resources/Profiles/Chrome.xml: <Client name="Chrome" redirect="Web" />
```

Previously, the universal transcode path selected the shipped **Generic**
profile by name. Generic is empty, while Chrome redirects to Web. MiSTerPlex now
uses its own profile name:

```text
X-Plex-Client-Profile-Name: MiSTerPlex
```

The header was tested with the XML absent: PMS fell back cleanly and streaming
continued, but delivered High/CABAC. Copying this file as `Generic.xml` is not
recommended because it could affect other PMS clients that also select Generic.

## Exact path on this PMS

The Plex container is named `plex`, and Docker maps `/home/shawn/plex/config` to `/config`. The profile is installed at:

```text
/home/shawn/plex/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml
```

Inside the container, the same file is:

```text
/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml
```

The `Profiles` directory was absent before the experiment; it now exists and
contains `MiSTerPlex.xml`.

## Restore / activation and disruption

If a Plex upgrade or container rebuild removes the file, restore it by copying
`assets/plex-profiles/MiSTerPlex.xml` back to the path above, then restart PMS:

```bash
docker restart plex
```

Expected disruption: active PMS streams disconnect and the server is unavailable
for a few seconds while the container restarts. Library data is not modified.

The absence symptom is specific: delivered stream probes return
`profile_idc=100`, `entropy_cabac=1`, B-slices present, and
`max_num_ref_frames=4` instead of the expected Baseline values below. The daemon
also logs a specific High/CABAC diagnostic naming the PMS profile as the likely
cause.

## Live guard: measure the delivered stream

Do not trust request parameters or the XML file when debugging decoder failures;
measure the stream PMS actually delivers. The dedicated live-PMS guard is:

```bash
PLEX_BASE=http://YOUR-PLEX-SERVER:32400 \
PLEX_TOKEN=... \
MISTERPLEX_BASELINE_KEY=/library/metadata/N \
make pms-baseline-check
```

This target is intentionally **not** part of `make unit` because it requires a
running PMS, a token, `ffmpeg`, and a known media item. If those inputs are
missing, it prints `SKIP-NOT-PASS` and exits non-zero; do not report that as a
pass.

The guard uses the same production transcode URL and FFmpeg headers as
`misterplexd`, extracts the delivered H.264 elementary stream, parses SPS/PPS,
and fails with an actionable message if PMS silently falls back to a stream the
FPGA cannot decode. The contract is exact:

```text
profile_idc=66
entropy_cabac=0
max_num_ref_frames=1
B-slices=0
coded=624x480
display=618x480
```

Raw delivered numbers are printed before interpretation:

```text
PMS_BASELINE_DELIVERED profile_idc=66 level_idc=30 pps_valid=1 entropy_cabac=0 max_num_ref_frames=1 coded=624x480 display=618x480 ...
PMS_BASELINE_SLICES vcl=300 idr=6 nonidr=294 i=6 p=294 b=0 other=0 ...
```

Failure names the violated field, for example:

```text
FAIL pms_baseline_profile: delivered stream violates MiSTerPlex 480p FPGA contract:
profile_idc=100, expected 66; entropy_cabac=1, expected 0; ...
```

Searchable symptom for missing/inactive profile: **delivered stream violates
MiSTerPlex 480p FPGA contract profile_idc=100 expected 66 MiSTerPlex.xml still
installed**.

`make unit` also runs `tests/unit/test_pms_baseline_gate.sh`, which points the
same parser at generated Annex-B streams and proves the gate goes red for each
fault it exists to catch:

| Injected stream | Required red symptom |
| --- | --- |
| High-profile SPS | `profile_idc=100, expected 66` |
| CABAC PPS | `entropy_cabac=1, expected 0` |
| Four reference frames | `max_num_ref_frames=4, expected 1` |
| B-slice VCL | `b_slices=1, expected 0` |

The unit proof also checks the live wrapper's absent-dependency path: missing
`PLEX_BASE`/`PLEX_TOKEN`/`MISTERPLEX_BASELINE_KEY` returns `77` and prints
`SKIP-NOT-PASS`, never a green pass.

Live host check on 2026-07-27 found no blocker: Docker was present, container
`plex` was running, the profile path existed and matched the repo copy, and the
PMS token was present in `Preferences.xml` (not recorded here). The HEVC Main
480p test item was found at `/library/metadata/3`, and the live gate passed:

```text
PMS_BASELINE_SOURCE live_pms=http://127.0.0.1:32400 key=/library/metadata/3
PMS_BASELINE_DELIVERED profile_idc=66 level_idc=30 pps_valid=1 entropy_cabac=0 max_num_ref_frames=1 coded=624x480 display=618x480 crop_flag=1 crop_lrtb=0,3,0,0 crop_unit=2x2
PMS_BASELINE_SLICES vcl=350 idr=7 nonidr=343 i=7 p=343 b=0 other=0 bytes=2519896
test_pms_baseline_profile: OK delivered Baseline/CAVLC/ref=1/no-B 624x480 stream
```

If this check becomes `SKIP-NOT-PASS` on another host, the human must provide
the missing item named by the script: `PLEX_BASE`, a PMS token, and a video
metadata key such as `MISTERPLEX_BASELINE_KEY=/library/metadata/N`.

## Rollback

One-step server rollback:

```bash
rm "/home/shawn/plex/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml" && docker restart plex
```

If MiSTerPlex has also been changed to send `X-Plex-Client-Profile-Name: MiSTerPlex`, client-side rollback is to restore `Generic` or remove the custom profile-name override.

## Delivered stream with the server-side profile installed

The profile was measured on the delivered Annex-B stream, not PMS XML:

```text
profile_idc=66
level_idc=30
PPS entropy_cabac=0
B-slices=0
max_num_ref_frames=1
vcl=300 idr=6 i=6 p=294 b=0 over a 12 s sample
coded=624x480 display=618x480 crop_lrtb=0,3,0,0 crop_unit=2x2
```

The GOP flags are honored: `keyint=50:min-keyint=25:scenecut=0` produced
exactly 6 IDR frames across 300 VCL slices, i.e. one IDR every 50 frames at
25 fps. Geometry remains coded `624x480` with right crop to display `618x480`;
the profile constrains codec tools, not padding to 640.

**⚠️ Geometry caveat (see §"PMS resolution sensitivity" below):** the 624 coded
width was measured from 16:9 content where x264's aspect fit produces 624
regardless of the requested width. Whether PMS delivers 624 or 640 for natively
4:3 content is **UNMEASURED**. Do not treat 624 as a guaranteed PMS property
without the decisive 4:3 experiment.

The presentation pipeline remains 640x480 by adding 11-pixel pillars around the
618x480 display window. The coded frame is 39x30 macroblocks (1170 MBs) with no
partial macroblocks, so DDR plane offsets stay `Y=0`, `U=299520`, `V=374400`
and strides stay `624/312/312`. If a future PMS/profile change produces any
other coded or display geometry, `pms-baseline-check` fails before anyone can
misdiagnose it as an RTL decode bug.

Pixel-format ownership is intentionally not duplicated here. This PMS/SPS gate
proves the codec tools and geometry of the delivered H.264 bitstream; the
hardware visual contract proves the DDR/presentation pixel format via the
golden `.provenance.json` sidecar and `--expected-pixel-format yuv420p`. The
canonical value for the RGB565→YUV420 migration is `yuv420p` (`i420` is accepted
only as an alias by the visual harness), matching w-osd's frame-format status
token and avoiding a second, competing pixel-format declaration in the PMS XML.

## PMS resolution sensitivity — OPEN QUESTION (corrected 2026-07-27)

**Standing claim:** PMS output was insensitive to requested width across 624–640
for 16:9 content; whether the request is honoured at all is **UNMEASURED**,
pending a 4:3 source.

### What was measured

All measurements below used a single test item: HEVC Main 696×540 (≈1.29:1,
effectively 16:9-derived). x264 fitted this within the requested bound and
produced 624×480 coded regardless of what width was requested:

| Request | Delivered coded | Status |
|---------|-----------------|--------|
| `videoResolution=640x480` | 624×480 | **MEASURED** |
| `videoResolution=624x480` | 624×480 | **MEASURED** |
| `width=640&height=480` | 624×480 | **MEASURED** |

**Three different requests produced one identical output.** This is evidence that
the output was **insensitive to the request** across the range tested — NOT
evidence that PMS honoured the 624 request.

### Why the previous conclusion ("PMS honours 624") was wrong

The source item's aspect ratio (696/540 ≈ 1.29) means x264's aspect-fit
produces 624 regardless of the requested width. The mechanism is: x264 fits the
longest dimension within the bound, rounds to macroblock boundaries, and the
result happens to be 624 for any request ≥624 against this content. **The
request could be ignored entirely and the output would be the same.**

This is the same error shape as `a6ec399` (measuring our own ffmpeg scale filter
and recording it as a property of the source): we measured an output that was
determined by content aspect ratio, not by our request, and recorded it as "PMS
honours our request."

### What is NOT measured — the decisive experiment

| Source aspect | Request | Expected if honoured | Expected if ignored | Status |
|---------------|---------|---------------------|--------------------:|--------|
| 16:9 (current item) | 640×480 | 624 (aspect fit) | 624 (aspect fit) | **Cannot distinguish** |
| 16:9 (current item) | 624×480 | 624 | 624 | **Cannot distinguish** |
| **4:3 native (≥1.30)** | **640×480** | **640** | **640** | **UNMEASURED** |
| **4:3 native (≥1.30)** | **624×480** | **624** | **640** | **UNMEASURED** — this is the decisive cell |

The only test that can distinguish "PMS honours width" from "PMS ignores width"
requires a source whose native aspect ratio would produce **different** coded
widths for 640 vs 624 requests. A natively 4:3 (or wider) source where
aspect-fit at 640 produces 640, tested against a 624 request, is the minimal
decisive experiment.

### Risk table for STREAM=1 width (cells labelled)

| Source aspect | Request 640×480 | Request 624×480 | Consequence for STREAM=1 |
|---------------|-----------------|-----------------|--------------------------|
| 16:9 (tested) | coded=624 **MEASURED** | coded=624 **MEASURED** | 39 MBs sufficient |
| 4:3 native | coded=640 **INFERRED** | coded=624 if honoured / 640 if ignored **INFERRED** | If 640: 40th MB column mandatory |
| Arbitrary (directH264) | passthrough **INFERRED** | passthrough **INFERRED** | Unbounded; MB-aligned gate required |

### Blocker

This host has no `PLEX_BASE` / `PLEX_TOKEN` / 4:3 test item. The decisive
experiment requires PMS access with a natively 4:3 source. **Options:**

1. Ask w-osd (who has PMS access on the lab host) to run `pms_baseline_probe`
   with a 4:3 item at both `videoResolution=640x480` and `videoResolution=624x480`.
2. Parent provides credentials and a 4:3 media key to this host.

Until the decisive experiment is run, **the 40th macroblock column question is
OPEN** — w-dpb, w-mc, and w-deblock should size their work for 40 MBs (1200)
as the worst case but need not commit until we have measurement.

## Salvage verdict for stranded 480p branches

These branches were inspected and adjudicated so they can be closed instead of
remaining parallel attempts:

| Branch / commit | Verdict | Reason |
| --- | --- | --- |
| `feat/a4-480p-server` / `216703b` | Salvaged | Its built-in `240p`/`480p` transcode profile table, `TRANSCODE_PROFILE`/`--transcode-profile` wiring, URL `videoProfile=baseline&videoLevel=30`, and 480p unit guards are ancestors of the current branch. |
| `feat/a4-pms-profile-prep` / `af339d6` | Salvaged and updated | Its `assets/plex-profiles/MiSTerPlex.xml` and initial recipe are ancestors; the current doc changes status from prepared-only to installed/load-bearing with live evidence and rollback. |
| `feat/a4-profile-header` / `edb5f40` | Salvaged | Its `X-Plex-Client-Profile-Name: MiSTerPlex` identity, suppression of counterproductive `X-Plex-Client-Profile-Extra` for that profile, MPEG-TS target, and High/CABAC diagnostics are ancestors. |
| `feat/a4-sps-baseline` / `b28e863` | Superseded | Its useful MPEG-TS/profile guard intent is covered by `edb5f40` plus the delivered-stream gate. It is not an ancestor of the current branch because its client-side-only assertions were weaker than the live SPS/PPS/slice gate and did not prove delivered refs/B-slices/geometry. |

## Direct Play / Direct Stream check for the current test item

The current source item is not useful for the H.264 FPGA decoder without transcoding. Metadata and source-part ffprobe reported:

```text
SOURCE_MEDIA container=mp4 videoCodec=hevc videoProfile=main videoResolution=480 width=696 height=540 bitrate=1065
SOURCE_VIDEO_STREAM codec=hevc profile=main level=90 width=696 height=540 frameRate=25.000 bitrate=900
PART_FFPROBE codec_name=hevc profile=Main width=696 height=540 coded_height=544 has_b_frames=2 level=90 avg_frame_rate=25/1 bit_rate=900397
```

PMS reports direct play OK for a web-like client profile, but that path is HEVC Main, not H.264 Baseline, so it does not make the hardware-decoder profile work moot. A direct stream/remux would preserve the HEVC video codec and is likewise not usable for the current H.264 decode path.
