#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/project" && pwd)"
cd "$ROOT"
OUT="$ROOT/../results/controller-v1"
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite a controller campaign" >&2; exit 2; }
mkdir -p "$OUT"
FIXTURE="$ROOT/tests/fixtures/p2_intra_controller/real_color_filter_off_320x240_1f.264"
read -r full matrix < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=color_range,color_space -of json "$FIXTURE" | python3 -c \
  'import json,sys;s=json.load(sys.stdin)["streams"][0];print(int(s.get("color_range")=="pc"),{"bt709":1,"bt470bg":5,"smpte170m":6}.get(s.get("color_space"),2))')
printf 'fixture=%s full_range=%s matrix=%s RBSP_ADDR_W=13 original_budget=12000000\n' \
  "$FIXTURE" "$full" "$matrix" > "$OUT/modes.txt"
sha256sum "$FIXTURE" "$0" "$ROOT/tests/rtl/p2_intra_controller_tb.sv" \
  "$ROOT/tests/rtl/p2_intra_controller_tb.cpp" > "$OUT/inputs.sha256"
for lease in 0 1; do
  env -u P2_RTL_SOURCE_DIR P2_RBSP_ADDR_W=13 P2_NATIVE_PUBLISH_LEASE="$lease" P2_STATIC_IDR_ONLY=0 \
    bash tests/unit/test_p2_intra_controller.sh "$FIXTURE" \
    > "$OUT/baseline-lease$lease.log" 2>&1 || {
      tail -60 "$OUT/baseline-lease$lease.log"; exit 1;
    }
  build="$ROOT/build/p2-intra-controller-13"
  if [[ "$lease" == 1 ]]; then build="$build-native-lease"; fi
  cp "$build/run.log" "$OUT/baseline-lease$lease.execution.log"
  cp "$build/run.actual.yuv" "$OUT/baseline-lease$lease.actual.yuv"
  cp "$build/run.ffmpeg.yuv" "$OUT/baseline-lease$lease.ffmpeg.yuv"
  sha256sum "$build/obj/Vp2_intra_controller_tb" > "$OUT/baseline-lease$lease.binary.sha256"
  grep -E 'CONTROLLER|PASS |TRANSACTIONS' "$OUT/baseline-lease$lease.execution.log"
done
for mode in reset vcl; do
  for stage in 0 1 2 3 17 18 19; do
    name="hdc-$mode-$stage"
    P2_HEADER_AT_END=1 P2_HDC_CANCEL="$mode" P2_HDC_CANCEL_STAGE="$stage" \
      "$build/obj/Vp2_intra_controller_tb" "$FIXTURE" "$OUT/baseline-lease1.ffmpeg.yuv" \
      "$OUT/$name.actual.yuv" "$full" "$matrix" > "$OUT/$name.log" 2>&1 || {
        tail -60 "$OUT/$name.log"; exit 1;
      }
    cmp "$OUT/$name.actual.yuv" "$OUT/baseline-lease1.ffmpeg.yuv"
    grep -E 'CONTROLLER|PASS |HADAMARD_CANCEL|TRANSACTIONS' "$OUT/$name.log"
  done
done
sha256sum --check --status "$OUT/inputs.sha256"
