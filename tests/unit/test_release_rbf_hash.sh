#!/usr/bin/env bash
# Guard: release packages must carry the exact hardware-validated v0.3.0 core.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

EXPECTED="41adb98c7a630b541091c22ce291be68"
SOURCE_RBF="${RELEASE_RBF_PATH:-release_artifacts/v0.3.0/Plex.rbf}"
status=0

# dist/ accumulates tarballs from older releases, which legitimately carry a
# different core than the current pinned one. Checking them unconditionally
# turns a stale local file into a permanent build failure, so by default only
# artifacts built from the current revision are checked. SCAN_ARTIFACTS=1
# checks every artifact and is what `make package` uses, so the package that
# actually ships is always verified.
version="${VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
scan_all="${SCAN_ARTIFACTS:-0}"
scanned_artifact=0

artifact_is_current() {
  [[ "$scan_all" == "1" ]] && return 0
  # Exact match only: a dirty tree is a different build from the tagged one,
  # so it must not be validated against the tagged tree's package.
  [[ "$1" == "misterplex-$version" ]]
}

report() {
  status=1
  echo "test_release_rbf_hash: FAIL - $1" >&2
}

check_hash() {
  local label="$1" actual="$2"
  if [[ "$actual" != "$EXPECTED" ]]; then
    report "$label md5 mismatch; expected $EXPECTED actual $actual"
  else
    echo "test_release_rbf_hash: OK $label md5=$actual"
  fi
}

if [[ ! -f "$SOURCE_RBF" ]]; then
  report "release source core missing: $SOURCE_RBF"
else
  check_hash "$SOURCE_RBF" "$(md5sum "$SOURCE_RBF" | awk '{print $1}')"
fi

if compgen -G "dist/misterplex-*.tar.gz" >/dev/null; then
  for tarball in dist/misterplex-*.tar.gz; do
    [[ -f "$tarball" ]] || continue
    if ! artifact_is_current "$(basename "$tarball" .tar.gz)"; then
      echo "test_release_rbf_hash: skipping stale artifact $tarball (built from another revision, not $version); SCAN_ARTIFACTS=1 to include it"
      continue
    fi
    listing="$(tar -tzf "$tarball")"
    if ! grep -Eq '/cores/Plex\.rbf$' <<<"$listing"; then
      report "$tarball does not contain cores/Plex.rbf"
      continue
    fi
    actual="$(tar --wildcards -xOzf "$tarball" '*/cores/Plex.rbf' | md5sum | awk '{print $1}')"
    check_hash "$tarball cores/Plex.rbf" "$actual"
    scanned_artifact=1
  done
fi

# The staging tree is rebuilt immediately before tarring, so it is current
# exactly when a current-version tarball is present.
if [[ "$scan_all" == "1" || "$scanned_artifact" == "1" ]] && [[ -d dist/stage-misterplex ]]; then
  if [[ ! -f dist/stage-misterplex/cores/Plex.rbf ]]; then
    report "dist/stage-misterplex exists but cores/Plex.rbf is missing"
  else
    check_hash "dist/stage-misterplex/cores/Plex.rbf" \
      "$(md5sum dist/stage-misterplex/cores/Plex.rbf | awk '{print $1}')"
  fi
elif [[ -d dist/stage-misterplex ]]; then
  echo "test_release_rbf_hash: skipping stale dist/stage-misterplex (no $version tarball to date it against); SCAN_ARTIFACTS=1 to include it"
fi

# Release gate: refuse to report success without having actually inspected a
# package, so a version/naming mismatch cannot turn this into a no-op.
if [[ "${REQUIRE_ARTIFACT:-0}" == "1" && "$scanned_artifact" != "1" ]]; then
  report "REQUIRE_ARTIFACT=1 but no package for $version was found to scan"
fi

exit "$status"
