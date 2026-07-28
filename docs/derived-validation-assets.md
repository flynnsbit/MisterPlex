Derived re-encoded validation asset, not original library content, and not evidence about what the user owns.

# Derived 624×480 Baseline/CAVLC validation asset

This record describes the disposable clip generated under `build/arm-profile-sample/` for decode/present profiling. The media file itself is intentionally not tracked, but this provenance record is tracked so later reports cannot confuse this asset with original-Part direct-play H.264 from the user's library.

## Scope

- Evidence class: **derived re-encoded validation asset**.
- Not evidence for: original library media being H.264, direct-play original-Part H.264, or real-library coverage at ≤480p.
- Use: a reproducible, real-image-statistics H.264 Baseline/CAVLC/ref=1/no-B workload for MiSTerPlex decoder and ARM-boundary profiling.

## Source

- PMS metadata key: `/library/metadata/3`.
- PMS part key: `/library/parts/1/1784673124/file.mp4`.
- Source codec/resolution: HEVC Main, 696×540, 25 fps.
- Source container md5 from the scratch fetch used for this run: `252c4a11be79e7fe08ff592fbdd44a03`.
- Census context: the scanned library had 8 items total: 7 synthetic H.264 items, 1 real HEVC item, and **0 real H.264 ≤480p original-Part items**.

## Encoder

- FFmpeg: `ffmpeg version n8.1.2 Copyright (c) 2000-2026 the FFmpeg developers`.
- libavcodec/libx264 as reported in the output: `Lavc62.28.102 libx264`.
- x264 core as reported by the encode log: `core 165 r3222 b35605a`.

## Regeneration commands

Set `PLEX_BASE` to the PMS base URL and provide `PLEX_TOKEN` without echoing it in logs. The token must not be committed or pasted into reports.

```bash
mkdir -p build/arm-profile-sample
curl -fL --retry 3 \
  -H "X-Plex-Token: ${PLEX_TOKEN:?}" \
  "${PLEX_BASE:?}/library/parts/1/1784673124/file.mp4" \
  -o build/arm-profile-sample/original_part_metadata3.hevc.mp4

ffmpeg -y \
  -i build/arm-profile-sample/original_part_metadata3.hevc.mp4 \
  -map 0:v:0 -an \
  -vf 'fps=25,scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2,format=yuv420p' \
  -frames:v 1800 \
  -c:v libx264 -profile:v baseline -level:v 3.0 \
  -x264-params 'cabac=0:bframes=0:ref=1:weightp=0:8x8dct=0:partitions=none:keyint=50:min-keyint=25:scenecut=0' \
  -pix_fmt yuv420p -movflags +faststart \
  build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4

ffmpeg -y \
  -i build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4 \
  -map 0:v:0 -c:v copy -bsf:v h264_mp4toannexb -f h264 \
  build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264
```

The encode flags are deliberately stricter than generic Baseline: CAVLC only, one reference frame, no B-slices, no weighted prediction, no 8×8 DCT, no sub-macroblock partitions, fixed 25 fps, and 1800 frames.

## Output

- MP4 path: `build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4`.
- Annex-B path: `build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264`.
- Output MP4 md5 from this run: `3fad246c17830b60f45759556765f83b`.
- Output Annex-B md5 from this run: `779f0d3aa0014e465db885647a18c765`.
- FFprobe fields independently checked on the MP4: `codec_name=h264`, `profile=Constrained Baseline`, `width=624`, `height=480`, `has_b_frames=0`, `level=30`, `nb_frames=1800`.

## `pms_baseline_probe` output

```text
PMS_BASELINE_SOURCE annexb=build/arm-profile-sample/derived_realcontent_624x480_baseline_ref1_nob_1800f.264
PMS_BASELINE_DELIVERED profile_idc=66 level_idc=30 pps_valid=1 entropy_cabac=0 max_num_ref_frames=1 coded=624x480 display=624x480 crop_flag=0 crop_lrtb=0,0,0,0 crop_unit=2x2
PMS_BASELINE_SLICES vcl=1800 idr=36 nonidr=1764 i=36 p=1764 b=0 other=0 bytes=12713118
test_pms_baseline_profile: OK delivered Baseline/CAVLC/ref=1/no-B 624x480 stream
```
