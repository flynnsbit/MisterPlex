#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="${ARM_PROFILE_ASSET_DIR:-$ROOT/artifacts/local/arm-profile-sample}"
PLEX_PART_PATH="${PLEX_PART_PATH:-/library/parts/1/1784673124/file.mp4}"
SOURCE="$ASSET_DIR/original_part_metadata3.hevc.mp4"
MP4="$ASSET_DIR/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4"
ANNEXB="$ASSET_DIR/derived_realcontent_624x480_baseline_ref1_nob_1800f.264"

if [[ -z "${PLEX_BASE:-}" || -z "${PLEX_TOKEN:-}" ]]; then
  echo "usage: PLEX_BASE=http://host:32400 PLEX_TOKEN=<secret> $0" >&2
  echo "optional: ARM_PROFILE_ASSET_DIR=$ASSET_DIR PLEX_PART_PATH=$PLEX_PART_PATH" >&2
  exit 2
fi

mkdir -p "$ASSET_DIR"

echo "ARM_PROFILE_ASSET_REGEN dir=$ASSET_DIR source_part=$PLEX_PART_PATH"
curl -fL --retry 3 \
  -H "X-Plex-Token: ${PLEX_TOKEN}" \
  "${PLEX_BASE%/}${PLEX_PART_PATH}" \
  -o "$SOURCE"

ffmpeg -y \
  -i "$SOURCE" \
  -map 0:v:0 -an \
  -vf 'fps=25,scale=624:480:force_original_aspect_ratio=decrease,pad=624:480:(ow-iw)/2:(oh-ih)/2,format=yuv420p' \
  -frames:v 1800 \
  -c:v libx264 -profile:v baseline -level:v 3.0 \
  -x264-params 'cabac=0:bframes=0:ref=1:weightp=0:8x8dct=0:partitions=none:keyint=50:min-keyint=25:scenecut=0' \
  -pix_fmt yuv420p -movflags +faststart \
  "$MP4"

ffmpeg -y \
  -i "$MP4" \
  -map 0:v:0 -c:v copy -bsf:v h264_mp4toannexb -f h264 \
  "$ANNEXB"

make -C "$ROOT" "$ROOT/build/pms_baseline_probe" >/dev/null
"$ROOT/build/pms_baseline_probe" --annexb "$ANNEXB"
"$ROOT/scripts/check_arm_profile_asset.sh"
