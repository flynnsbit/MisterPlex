#!/usr/bin/env bash
set -euo pipefail
export P2_RBSP_ADDR_W=13 P2_STATIC_IDR_ONLY=0 P2_NATIVE_PUBLISH_LEASE=0
FIXTURE="$PWD/tests/fixtures/p2_intra_controller/real_color_filter_off_320x240_1f.264"
read -r FULL MATRIX < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=color_range,color_space -of json "$FIXTURE" | python3 -c \
  'import json,sys;s=json.load(sys.stdin)["streams"][0];print(int(s.get("color_range")=="pc"),{"bt709":1,"bt470bg":5,"smpte170m":6}.get(s.get("color_space"),2))')
echo "=== Existing composed controller fixture: 8KiB, no native lease ==="
bash tests/unit/test_p2_intra_controller.sh "$FIXTURE"
BUILD="$PWD/build/p2-intra-controller-13"
sha256sum "$BUILD/obj/Vp2_intra_controller_tb"
for MODE in reset vcl; do
  for STAGE in 1 2 3 4 0; do
    LABEL="chroma-$MODE-stage$STAGE"
    P2_CHROMA_CANCEL="$MODE" P2_CHROMA_CANCEL_STAGE="$STAGE" \
      "$BUILD/obj/Vp2_intra_controller_tb" "$FIXTURE" "$BUILD/run.ffmpeg.yuv" \
      "$BUILD/$LABEL.actual.yuv" "$FULL" "$MATRIX" >"$BUILD/$LABEL.log" 2>&1 || {
        tail -60 "$BUILD/$LABEL.log"; exit 1;
      }
    grep -E 'CHROMA_CANCEL|CONTROLLER cycles|YUV mismatches|CHROMA_TRANSACTIONS' "$BUILD/$LABEL.log"
    cmp "$BUILD/$LABEL.actual.yuv" "$BUILD/run.ffmpeg.yuv"
  done
done
echo "=== Existing native-lease and reset/VCL handoff cases with the same 8KiB source ==="
export P2_NATIVE_PUBLISH_LEASE=1
bash tests/unit/test_p2_intra_controller.sh "$FIXTURE"
BUILD="$PWD/build/p2-intra-controller-13-native-lease"
sha256sum "$BUILD/obj/Vp2_intra_controller_tb"
for MODE in reset vcl; do
  LABEL="native-$MODE"
  P2_NATIVE_CANCEL="$MODE" "$BUILD/obj/Vp2_intra_controller_tb" \
    "$FIXTURE" "$BUILD/run.ffmpeg.yuv" "$BUILD/$LABEL.actual.yuv" "$FULL" "$MATRIX" \
    >"$BUILD/$LABEL.log" 2>&1 || { tail -60 "$BUILD/$LABEL.log"; exit 1; }
  grep -E 'NATIVE_CANCEL|CONTROLLER cycles|YUV mismatches|CHROMA_TRANSACTIONS' "$BUILD/$LABEL.log"
  cmp "$BUILD/$LABEL.actual.yuv" "$BUILD/run.ffmpeg.yuv"
done
echo "PASS controller14 exact pictures: ten chroma-stage cancellation/replays, two baseline lease modes, two existing native-lease cancellations/replays"
