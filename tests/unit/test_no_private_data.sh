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
# download. Scan both the staging tree and extracted release tarballs when
# present so private lab values cannot leak through copied/generated files.
add_tree "dist/stage-misterplex"
scan_root="$ROOT/build/private-data-scan"
if compgen -G "dist/misterplex-*.tar.gz" >/dev/null; then
  rm -rf "$scan_root"
  mkdir -p "$scan_root"
  for tarball in dist/misterplex-*.tar.gz; do
    [[ -f "$tarball" ]] || continue
    safe_name="$(basename "$tarball" .tar.gz)"
    mkdir -p "$scan_root/$safe_name"
    tar -xzf "$tarball" -C "$scan_root/$safe_name"
    add_tree "$scan_root/$safe_name"
  done
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
