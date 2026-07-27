#!/usr/bin/env bash
# Guard: no personal Plex server addresses or live Plex tokens may be committed.
#
# MiSTerPlex is a public repo. Lab worktrees routinely hardcode the maintainer's
# Plex Media Server address and tokens while iterating; this test makes such a
# value fail the build instead of shipping in a release tarball.
#
# MISTER_HOST (192.168.1.183) is deliberately allowed: it is the documented
# default MiSTer address used throughout the tooling, not a Plex credential.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

status=0
scan_files=()

report() {
  status=1
  echo "test_no_private_data: FAIL - $1" >&2
}

add_tree() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  local found=()
  mapfile -d '' -t found < <(find "$dir" -type f -not -path '*/.git/*' -print0)
  scan_files+=("${found[@]}")
}

if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  mapfile -t tracked_files < <(git ls-files)
  scan_files+=("${tracked_files[@]}")
else
  add_tree "."
fi

# Generated packages are not git-tracked, but they are exactly what users
# download, so they are scanned too.
#
# Scope matters here: dist/ accumulates tarballs from every past build, and
# those old artifacts can contain values that were legitimately removed from
# the source since. Scanning them unconditionally made this test fail forever
# on any machine holding a stale tarball, which is a property of local
# filesystem history rather than of the code under test. Only artifacts built
# from the current tree are scanned by default; SCAN_ARTIFACTS=1 forces every
# artifact to be scanned and is what `make package` uses, so whatever actually
# ships is always covered.
version="${VERSION:-$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)}"
scan_all="${SCAN_ARTIFACTS:-0}"

artifact_is_current() {
  [[ "$scan_all" == "1" ]] && return 0
  local name="$1"
  [[ "$name" == "misterplex-$version" || "$name" == "misterplex-${version%-dirty}" ]]
}

scan_root="$ROOT/build/private-data-scan"
if compgen -G "dist/misterplex-*.tar.gz" >/dev/null; then
  rm -rf "$scan_root"
  mkdir -p "$scan_root"
  for tarball in dist/misterplex-*.tar.gz; do
    [[ -f "$tarball" ]] || continue
    safe_name="$(basename "$tarball" .tar.gz)"
    if ! artifact_is_current "$safe_name"; then
      echo "test_no_private_data: skipping stale artifact $tarball (built from another revision, not $version); SCAN_ARTIFACTS=1 to include it"
      continue
    fi
    mkdir -p "$scan_root/$safe_name"
    tar -xzf "$tarball" -C "$scan_root/$safe_name"
    add_tree "$scan_root/$safe_name"
    scanned_artifact=1
  done
fi

# package_release.sh rebuilds the staging tree immediately before tarring it,
# so it is current exactly when a current-version tarball is present.
if [[ "$scan_all" == "1" || "${scanned_artifact:-0}" == "1" ]]; then
  add_tree "dist/stage-misterplex"
elif [[ -d "dist/stage-misterplex" ]]; then
  echo "test_no_private_data: skipping stale dist/stage-misterplex (no $version tarball to date it against); SCAN_ARTIFACTS=1 to include it"
fi

files=()
for f in "${scan_files[@]}"; do
  [[ -f "$f" ]] && files+=("$f")
done

# 1. Private-range PMS addresses. Loopback is fine (test servers), and the
#    documented MiSTer host default is not a Plex credential.
hits="$(grep -a -nE '(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+):32400' "${files[@]}" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  report "hardcoded private Plex server address found; use a PMS_URL env var or a YOUR-PLEX-SERVER placeholder"
  printf '%s\n' "$hits" >&2
fi

# 2. Literal Plex tokens. Placeholders and redactions are fine.
tok="$(grep -a -nE 'X-Plex-Token[=:] *[A-Za-z0-9_-]{16,}' "${files[@]}" 2>/dev/null \
  | grep -viE 'REDACTED|YOUR[_-]?PLEX|PLACEHOLDER|<[^>]*>|\$\{|\$[A-Za-z_]|xxxx|\.\.\.' || true)"
if [[ -n "$tok" ]]; then
  report "literal X-Plex-Token found"
  printf '%s\n' "$tok" >&2
fi

if [[ $status -eq 0 ]]; then
  echo "test_no_private_data: OK"
fi
exit $status
