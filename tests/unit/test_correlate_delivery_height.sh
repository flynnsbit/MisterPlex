#!/bin/sh
# Host gate for correlate_delivery_height_collapse.sh (synthetic log).
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<'EOF'
media: spawn single-process ffmpeg ...
media: GEOM reason=scale_pad_crop_flags identity_skip=0
media: measured_delivery=624x350 measured_delivery_src=measured
media: frames=100 vfps=12.5 pfps=7.1 drops=40 av_drift_ms=+120 wall_s=10.0
media: frames=200 vfps=13.0 pfps=8.0 drops=90 av_drift_ms=+200 wall_s=20.0
media: session end foo
media: spawn single-process ffmpeg ...
media: measured_delivery=624x480 measured_delivery_src=measured
media: frames=500 vfps=23.8 pfps=23.7 drops=7 av_drift_ms=-36 wall_s=30.0
media: frames=1000 vfps=23.7 pfps=23.7 drops=7 av_drift_ms=-35 wall_s=50.0
EOF

out=$(sh "$ROOT_DIR/tools/correlate_delivery_height_collapse.sh" "$tmp")
echo "$out" | grep -q 'COLLAPSE_SHORT' || { echo "FAIL short collapse"; echo "$out"; exit 1; }
echo "$out" | grep -q 'HEALTHY_480' || { echo "FAIL 480 healthy"; echo "$out"; exit 1; }
echo "$out" | grep -q 'RESULT=HIT_PRE_REG' || { echo "FAIL HIT"; echo "$out"; exit 1; }

# inverted MISS
cat >"$tmp" <<'EOF'
media: spawn single-process x
media: measured_delivery=624x350
media: frames=1 vfps=23.9 pfps=23.9 drops=0 av_drift_ms=-30 wall_s=5.0
media: session end
media: spawn single-process y
media: measured_delivery=624x480
media: frames=1 vfps=10.0 pfps=8.0 drops=50 av_drift_ms=+100 wall_s=5.0
media: frames=2 vfps=11.0 pfps=8.0 drops=80 av_drift_ms=+120 wall_s=10.0
EOF
out=$(sh "$ROOT_DIR/tools/correlate_delivery_height_collapse.sh" "$tmp")
echo "$out" | grep -q 'RESULT=MISS_PRE_REG' || { echo "FAIL MISS inverted"; echo "$out"; exit 1; }

echo "RESULT=PASS test_correlate_delivery_height"
exit 0
