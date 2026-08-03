#!/usr/bin/env bash
# Package the tracked lab pair ddr-c5382bee-509b0c75 (stamped daemon from ba2ec313).
#
# Observed defect (parent HW 2026-08-02): the prior default pin e9f79de2 lacks
# delivery-geometry measurement (measured=/desync_risk=) and regresses 480p on
# real PMS delivery 624x350 (green field + duplicated TREK24). Shipping that
# pin as "validated" is a user-visible release defect.
#
# This wrapper points package_release.sh at
# release_artifacts/ddr-c5382bee-509b0c75/ (tracked, force-added) and fails
# closed unless:
#   - MANIFEST.md5 matches on-disk binaries
#   - daemon_stamp_check --require-stamped (no historical unstamped allow)
#   - capability strings for measured delivery are present in the binary
#   - pair_ship_policy → PAIR_OK
#
# LAB pair packaging, not daily-driver glass promotion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAIR_DIR="${PAIR_DIR:-$ROOT/release_artifacts/ddr-c5382bee-509b0c75}"
RBF="$PAIR_DIR/Plex.rbf"
DAEMON="$PAIR_DIR/misterplexd"
MANIFEST="$PAIR_DIR/MANIFEST.md5"
EXPECT_CORE=c5382bee73cecdee8220b811e529c297
EXPECT_DAEMON=509b0c7592e0e9e38686f9eb8e2cb047
EXPECT_STAMP_REV=ba2ec3139133
# Capability markers the 480p regression lacked (parent-measured defect class).
CAP_MARKERS=(
  "desync_risk="
  "DELIVERY_MISMATCH measured="
)

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

# Refuse unstamped / historical md5-only pins as the default ship path.
# Do NOT use --allow-matrix-pin here — that is how e9f79de2 slipped through.
stamp_out=$("$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$DAEMON" 2>&1) || {
  echo "ERROR: daemon must be stamped (git_rev=…); refuse md5-only pin: $stamp_out" >&2
  exit 7
}
echo "$stamp_out"
printf '%s\n' "$stamp_out" | grep -q "git_rev=${EXPECT_STAMP_REV}" || {
  echo "ERROR: expected git_rev=${EXPECT_STAMP_REV} in stamp output" >&2
  echo "got: $stamp_out" >&2
  exit 7
}

# Capability gate: binary must contain delivery-geometry markers (not md5-keyed).
# Use grep -aF on the file directly — `strings | grep -q` under `set -o pipefail`
# returns 141 (SIGPIPE) when grep exits early on a match, which falsely looks like CAP_MISS.
cap_ok=0
cap_miss=0
for m in "${CAP_MARKERS[@]}"; do
  if grep -aF -q -- "$m" "$DAEMON"; then
    cap_ok=$((cap_ok + 1))
    echo "CAP_OK marker='$m'"
  else
    cap_miss=$((cap_miss + 1))
    echo "CAP_MISS marker='$m'" >&2
  fi
done
echo "CAP_APPLIED ok=$cap_ok miss=$cap_miss want=${#CAP_MARKERS[@]}"
if [ "$cap_miss" -ne 0 ] || [ "$cap_ok" -ne "${#CAP_MARKERS[@]}" ]; then
  echo "ERROR: daemon lacks delivery-geometry capability markers (480p regression class)" >&2
  exit 8
fi

pair_out=$("$ROOT/scripts/pair_ship_policy.sh" check "$core_md5" "$dae_md5" 2>&1) || {
  echo "ERROR: pair_ship_policy refused tracked pair: $pair_out" >&2
  exit 6
}
echo "$pair_out"
printf '%s\n' "$pair_out" | grep -q 'PAIR_OK' || {
  echo "ERROR: expected PAIR_OK in policy output" >&2
  exit 6
}
printf '%s\n' "$pair_out" | grep -q 'id=ddr-c5382bee-509b0c75' || {
  echo "ERROR: expected pair id=ddr-c5382bee-509b0c75" >&2
  exit 6
}

# Behavioural vf gate: the daemon being packaged must produce whole bank frames
# and live chroma for a non-bank-exact delivery (real PMS RK6 is 624x350).
# Parent 2026-08-02: the previous pin desynced here and rendered a green field
# on glass while every other gate stayed green.
if ! vf_out=$("$ROOT/scripts/vf_delivery_behaviour_check.sh" "$DAEMON" 2>&1); then
  echo "ERROR: vf delivery behaviour gate refused daemon:" >&2
  printf '%s\n' "$vf_out" >&2
  exit 7
fi
printf '%s\n' "$vf_out"

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
export VERSION="${VERSION:-ddr-c5382bee-509b0c75}"
export OUT_DIR="${OUT_DIR:-$ROOT/dist}"

echo "Invoking package_release.sh VERSION=$VERSION"
"$ROOT/scripts/package_release.sh"
echo "package_validated_pair: OK"
