#!/usr/bin/env bash
# Guard: release packages must carry the exact hardware-validated v0.3.0 core.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

EXPECTED="41adb98c7a630b541091c22ce291be68"
SOURCE_RBF="${RELEASE_RBF_PATH:-release_artifacts/v0.3.0/Plex.rbf}"
status=0

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

if [[ -d dist/stage-misterplex ]]; then
  if [[ ! -f dist/stage-misterplex/cores/Plex.rbf ]]; then
    report "dist/stage-misterplex exists but cores/Plex.rbf is missing"
  else
    check_hash "dist/stage-misterplex/cores/Plex.rbf" \
      "$(md5sum dist/stage-misterplex/cores/Plex.rbf | awk '{print $1}')"
  fi
fi

if compgen -G "dist/misterplex-*.tar.gz" >/dev/null; then
  for tarball in dist/misterplex-*.tar.gz; do
    [[ -f "$tarball" ]] || continue
    listing="$(tar -tzf "$tarball")"
    if ! grep -Eq '/cores/Plex\.rbf$' <<<"$listing"; then
      report "$tarball does not contain cores/Plex.rbf"
      continue
    fi
    actual="$(tar --wildcards -xOzf "$tarball" '*/cores/Plex.rbf' | md5sum | awk '{print $1}')"
    check_hash "$tarball cores/Plex.rbf" "$actual"
  done
fi

exit "$status"
