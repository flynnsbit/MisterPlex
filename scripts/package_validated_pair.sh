#!/usr/bin/env bash
# Package the tracked hardware-validated lab pair ddr-c5382bee-e9f79de2.
#
# Observed defect: the only binaries that satisfy pair_ship_policy lived under
# gitignored paths (.agent-work/*.rbf, artifacts/daemon-pins/*), so a clean
# clone could never assemble a release. This wrapper points package_release.sh
# at release_artifacts/ddr-c5382bee-e9f79de2/ (tracked) and fails closed if the
# manifest md5s drift.
#
# This is LAB pair packaging, not daily-driver glass promotion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAIR_DIR="${PAIR_DIR:-$ROOT/release_artifacts/ddr-c5382bee-e9f79de2}"
RBF="$PAIR_DIR/Plex.rbf"
DAEMON="$PAIR_DIR/misterplexd"
MANIFEST="$PAIR_DIR/MANIFEST.md5"
EXPECT_CORE=c5382bee73cecdee8220b811e529c297
EXPECT_DAEMON=e9f79de217982aff44207664fdb945c5

echo "=== package_validated_pair ==="
echo "PAIR_DIR=$PAIR_DIR"

if [ ! -f "$RBF" ] || [ ! -f "$DAEMON" ] || [ ! -f "$MANIFEST" ]; then
  echo "ERROR: tracked pair incomplete under $PAIR_DIR" >&2
  echo "       need Plex.rbf + misterplexd + MANIFEST.md5 (force-added past *.rbf ignore)" >&2
  exit 1
fi

echo "Verifying MANIFEST.md5…"
(
  cd "$PAIR_DIR"
  md5sum -c MANIFEST.md5
)

core_md5=$(md5sum "$RBF" | awk '{print $1}')
dae_md5=$(md5sum "$DAEMON" | awk '{print $1}')
if [ "$core_md5" != "$EXPECT_CORE" ]; then
  echo "ERROR: core md5 $core_md5 != $EXPECT_CORE" >&2
  exit 2
fi
if [ "$dae_md5" != "$EXPECT_DAEMON" ]; then
  echo "ERROR: daemon md5 $dae_md5 != $EXPECT_DAEMON" >&2
  exit 2
fi

# Behavioural vf delivery (parent 2026-08-02 green-field regression, redesigned
# artifact-only): historical pin uses legacy identity vf policy and FAILS
# 624x350 bank-byte + chroma checks. Refuse ship until pair is re-pinned to a
# daemon whose vf FOAR-pins coded-bank output. No md5 allow/deny; no bypass.
if ! vf_out=$("$ROOT/scripts/vf_delivery_behaviour_check.sh" "$DAEMON" 2>&1); then
  echo "ERROR: tracked pair daemon fails vf delivery behaviour (will not ship):" >&2
  echo "$vf_out" >&2
  echo "ACTION: w-promote must rebuild ARM misterplexd with product FOAR policy" >&2
  echo "        and re-pin release_artifacts/; do not weaken this check." >&2
  exit 7
fi
echo "$vf_out"

pair_out=$("$ROOT/scripts/pair_ship_policy.sh" check "$core_md5" "$dae_md5" 2>&1) || {
  echo "ERROR: pair_ship_policy refused tracked pair: $pair_out" >&2
  exit 6
}
echo "$pair_out"
printf '%s\n' "$pair_out" | grep -q 'PAIR_OK' || {
  echo "ERROR: expected PAIR_OK in policy output" >&2
  exit 6
}
# ffmpeg: prefer tracked release_artifacts path, then env, then allow-no.
if [ -z "${FFMPEG_ARMHF:-}" ]; then
  if [ -f "$ROOT/release_artifacts/ffmpeg-armhf/ffmpeg" ]; then
    export FFMPEG_ARMHF="$ROOT/release_artifacts/ffmpeg-armhf/ffmpeg"
  fi
fi
if [ -z "${FFMPEG_ARMHF:-}" ] || [ ! -f "${FFMPEG_ARMHF}" ]; then
  if [ "${PACKAGE_ALLOW_NO_FFMPEG:-}" != "1" ]; then
    echo "ERROR: no armhf ffmpeg. Options:" >&2
    echo "  1) ./scripts/fetch_release_ffmpeg.sh   # md5-gated copy/fetch" >&2
    echo "  2) FFMPEG_ARMHF=/path/to/ffmpeg $0" >&2
    echo "  3) PACKAGE_ALLOW_NO_FFMPEG=1 $0     # pair-only tarball" >&2
    exit 5
  fi
  export PACKAGE_ALLOW_NO_FFMPEG=1
  echo "package_validated_pair: PACKAGE_ALLOW_NO_FFMPEG=1 (pair-only; no bundled ffmpeg)"
fi

export RBF_PATH="$RBF"
export DAEMON_PATH="$DAEMON"
export VERSION="${VERSION:-ddr-c5382bee-e9f79de2}"
export OUT_DIR="${OUT_DIR:-$ROOT/dist}"

echo "Invoking package_release.sh VERSION=$VERSION"
"$ROOT/scripts/package_release.sh"
echo "package_validated_pair: OK"
