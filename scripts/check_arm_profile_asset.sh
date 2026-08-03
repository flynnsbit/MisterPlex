#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_DIR="${ARM_PROFILE_ASSET_DIR:-$ROOT/artifacts/local/arm-profile-sample}"
ANNEXB="$ASSET_DIR/derived_realcontent_624x480_baseline_ref1_nob_1800f.264"
MP4="$ASSET_DIR/derived_realcontent_624x480_baseline_ref1_nob_1800f.mp4"
EXPECTED_ANNEXB_SHA="41f2769189bdceb3c30315bf557e44e01d016d48c3eca8507ceb6eed51919e04"
EXPECTED_ANNEXB_MD5="779f0d3aa0014e465db885647a18c765"
EXPECTED_MP4_MD5="3fad246c17830b60f45759556765f83b"

if [[ ! -f "$ANNEXB" || ! -f "$MP4" ]]; then
  echo "ASSET_EXPIRED missing asset_dir=$ASSET_DIR annexb=$ANNEXB mp4=$MP4"
  exit 77
fi

annexb_sha="$(sha256sum "$ANNEXB" | awk '{print $1}')"
annexb_md5="$(md5sum "$ANNEXB" | awk '{print $1}')"
mp4_md5="$(md5sum "$MP4" | awk '{print $1}')"

if [[ "$annexb_sha" != "$EXPECTED_ANNEXB_SHA" ]]; then
  echo "ASSET_EXPIRED annexb_sha_mismatch got=$annexb_sha want=$EXPECTED_ANNEXB_SHA path=$ANNEXB"
  exit 77
fi
if [[ "$annexb_md5" != "$EXPECTED_ANNEXB_MD5" ]]; then
  echo "ASSET_EXPIRED annexb_md5_mismatch got=$annexb_md5 want=$EXPECTED_ANNEXB_MD5 path=$ANNEXB"
  exit 77
fi
if [[ "$mp4_md5" != "$EXPECTED_MP4_MD5" ]]; then
  echo "ASSET_EXPIRED mp4_md5_mismatch got=$mp4_md5 want=$EXPECTED_MP4_MD5 path=$MP4"
  exit 77
fi

echo "ASSET_OK dir=$ASSET_DIR annexb_sha=$annexb_sha annexb_md5=$annexb_md5 mp4_md5=$mp4_md5"
