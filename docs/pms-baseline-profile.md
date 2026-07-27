# Prepared PMS profile for MiSTerPlex Baseline transcodes

Status: **prepared only**. Do not install without explicit user approval; this changes the user's Plex Media Server profile set and requires a PMS restart.

## Why this exists

Client-only requests are not enough on this PMS. The sweep in `build/misterplex-agent-W-A4.txt` found every working HTTP/mpegts variant delivered the same stream despite `videoProfile=baseline&videoLevel=30` and profile-extra limitations:

| Request family | Delivered result |
| --- | --- |
| URL params only | `profile_idc=100`, `cabac=1`, B=115/12s |
| `video.profile`/`video.level` profile-extra limitations | `profile_idc=100`, `cabac=1`, B=115/12s |
| `video.h264Profile`/`video.h264Level` match and notMatch forms | `profile_idc=100`, `cabac=1`, B=115/12s |
| Generic vs Chrome profile name | `profile_idc=100`, `cabac=1`, B=115/12s |
| `640x480`, `624x480`, and `width=640&height=480` | coded `624x480`, display `618x480` |

The prepared server-side profile is `assets/plex-profiles/MiSTerPlex.xml`. It constrains the HTTP streaming target to H.264/AAC in MPEG-TS and adds x264 flags for Baseline/CAVLC, no B-slices, one reference frame, weighted prediction off, no 8x8 DCT, no sub-macroblock partitions, and a bounded GOP.

## Current shipped profile match

For universal transcode playback, `misterplexd` sends these client identity headers from `arm/misterplexd/plex_resolve.cpp`:

```text
X-Plex-Client-Identifier: misterplex
X-Plex-Product: Plex Web
X-Plex-Version: 4.125.0
X-Plex-Platform: Chrome
X-Plex-Platform-Version: 120.0
X-Plex-Device: Linux
X-Plex-Device-Name: Chrome
X-Plex-Client-Profile-Name: Generic
X-Plex-Model: bundled
X-Plex-Provides: player
```

The PMS container's shipped profile resources show:

```text
/usr/lib/plexmediaserver/Resources/Profiles/Generic.xml: <Client name="Generic" />
/usr/lib/plexmediaserver/Resources/Profiles/Chrome.xml: <Client name="Chrome" redirect="Web" />
```

So the universal transcode path currently selects the shipped **Generic** profile by name. Generic is empty, while Chrome redirects to Web. To use the prepared profile without overriding Generic globally, MiSTerPlex should change its transcode identity to:

```text
X-Plex-Client-Profile-Name: MiSTerPlex
```

That client-header change is ours. The alternative, copying this file as `Generic.xml`, is not recommended because it could affect other PMS clients that also select Generic.

## Exact path on this PMS

The Plex container is named `plex`, and Docker maps `/home/shawn/plex/config` to `/config`. Therefore the prepared profile would be installed at:

```text
/home/shawn/plex/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml
```

Inside the container, the same file is:

```text
/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml
```

The `Profiles` directory is currently absent in this install, so installation would first create it, then copy `assets/plex-profiles/MiSTerPlex.xml` there.

## Activation and disruption

Safest activation is a Plex Media Server restart after copying the XML, for this install:

```bash
docker restart plex
```

Expected disruption: active PMS streams disconnect and the server is unavailable while the container restarts. Library data is not modified.

## Rollback

One-step server rollback:

```bash
rm "/home/shawn/plex/config/Library/Application Support/Plex Media Server/Profiles/MiSTerPlex.xml" && docker restart plex
```

If MiSTerPlex has also been changed to send `X-Plex-Client-Profile-Name: MiSTerPlex`, client-side rollback is to restore `Generic` or remove the custom profile-name override.

## Pre-committed expected delivered stream if the server-side profile works

The next experiment must judge the delivered bitstream, not PMS XML. Success means the extracted Annex-B stream reports:

```text
profile_idc=66
level_idc=30
PPS entropy_cabac=0
B-slices=0
max_num_ref_frames=1
```

Geometry may still remain coded `624x480` with right crop to display `618x480`; the profile is intended to constrain codec tools, not force padding to 640.

## Direct Play / Direct Stream check for the current test item

The current source item is not useful for the H.264 FPGA decoder without transcoding. Metadata and source-part ffprobe reported:

```text
SOURCE_MEDIA container=mp4 videoCodec=hevc videoProfile=main videoResolution=480 width=696 height=540 bitrate=1065
SOURCE_VIDEO_STREAM codec=hevc profile=main level=90 width=696 height=540 frameRate=25.000 bitrate=900
PART_FFPROBE codec_name=hevc profile=Main width=696 height=540 coded_height=544 has_b_frames=2 level=90 avg_frame_rate=25/1 bit_rate=900397
```

PMS reports direct play OK for a web-like client profile, but that path is HEVC Main, not H.264 Baseline, so it does not make the hardware-decoder profile work moot. A direct stream/remux would preserve the HEVC video codec and is likewise not usable for the current H.264 decode path.
