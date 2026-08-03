#!/usr/bin/env bash
# Stage a verified static armhf ffmpeg for package_release.sh.
#
# Observed defect: package_release defaults to
#   $HOME/Projects/mistercast-linux/third_party/ffmpeg-armhf/ffmpeg
# which is machine-local and absent on clean checkouts — same disease as
# gitignored RBF/daemon pins. This script fails closed unless the binary's
# md5 matches the pinned value (no silent wrong ffmpeg).
#
# Does NOT download from the network by default (reproducible offline lab).
# Provide a local source via FFMPEG_ARMHF or --from PATH.
#
# Pinned build: John Van Sickle FFmpeg 7.0.2 static armhf
#   md5 6493ebc2a1c1732ce4d52a969e162578  (measured parent lab host)
#   bytes 31793580
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${DEST_DIR:-$ROOT/release_artifacts/ffmpeg-armhf}"
DEST="$DEST_DIR/ffmpeg"
EXPECT_MD5="${FFMPEG_EXPECT_MD5:-6493ebc2a1c1732ce4d52a969e162578}"
EXPECT_BYTES="${FFMPEG_EXPECT_BYTES:-31793580}"
FROM="${FFMPEG_ARMHF:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=$2; shift 2 ;;
    --dest-dir) DEST_DIR=$2; DEST="$DEST_DIR/ffmpeg"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "usage: $0 [--from PATH] [--dest-dir DIR]" >&2
      exit 1
      ;;
  esac
done

if [ -z "$FROM" ]; then
  # Common lab locations (never invent a download URL without operator pin).
  for cand in \
    "$HOME/Projects/mp-wt-feed/build/ffmpeg-symbol-check/ffmpeg-7.0.2-armhf-static/ffmpeg" \
    "$HOME/Projects/mistercast-linux/third_party/ffmpeg-armhf/ffmpeg" \
    "$ROOT/release_artifacts/ffmpeg-armhf/ffmpeg"
  do
    if [ -f "$cand" ]; then
      FROM=$cand
      break
    fi
  done
fi

if [ -z "$FROM" ] || [ ! -f "$FROM" ]; then
  echo "FFMPEG_FETCH_FAIL reason=no_source" >&2
  echo "Provide FFMPEG_ARMHF=/path/to/ffmpeg-7.0.2-armhf-static or --from PATH" >&2
  echo "Expected md5=$EXPECT_MD5 bytes=$EXPECT_BYTES (John Van Sickle 7.0.2 armhf static)" >&2
  echo "Network fetch is intentionally not automated here; pin the binary offline." >&2
  exit 1
fi

got_md5=$(md5sum "$FROM" | awk '{print $1}')
got_bytes=$(wc -c <"$FROM" | tr -d ' ')
echo "fetch_release_ffmpeg: from=$FROM md5=$got_md5 bytes=$got_bytes"

if [ -z "$got_md5" ] || [ "${#got_md5}" -ne 32 ]; then
  echo "FFMPEG_FETCH_FAIL reason=malformed_md5 got='$got_md5'" >&2
  exit 3
fi
if [ "$got_md5" != "$EXPECT_MD5" ]; then
  echo "FFMPEG_FETCH_FAIL reason=md5_mismatch got=$got_md5 want=$EXPECT_MD5" >&2
  exit 2
fi
if [ "$got_bytes" != "$EXPECT_BYTES" ]; then
  echo "FFMPEG_FETCH_FAIL reason=size_mismatch got=$got_bytes want=$EXPECT_BYTES" >&2
  exit 2
fi

mkdir -p "$DEST_DIR"
cp -a "$FROM" "$DEST"
chmod +x "$DEST"
# Best-effort licence sidecar from source dir
src_dir=$(dirname "$FROM")
for lic in GPLv3.txt readme.txt LICENSE; do
  [ -f "$src_dir/$lic" ] && cp -a "$src_dir/$lic" "$DEST_DIR/"
done
cat >"$DEST_DIR/MANIFEST.md5" <<EOF
$EXPECT_MD5  ffmpeg
EOF
(
  cd "$DEST_DIR"
  md5sum -c MANIFEST.md5
)
echo "FFMPEG_FETCH_OK path=$DEST md5=$EXPECT_MD5"
echo "NOTE: release_artifacts/ffmpeg-armhf/ is gitignored by default (size ~32MB)."
echo "      Pair packaging works without it via PACKAGE_ALLOW_NO_FFMPEG=1."
echo "      To track ffmpeg in git deliberately: git add -f $DEST"
exit 0
