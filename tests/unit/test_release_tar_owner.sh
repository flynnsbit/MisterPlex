#!/usr/bin/env bash
# Release tarball ownership gate.
#
# OBSERVED DEFECT (parent, device 192.168.1.183, 2026-08-02):
#   /media/fat is exfat — no UNIX ownership. A release tarball built as lab
#   uid/gid 1000 makes plain `tar xzf` print
#     "Cannot change ownership to uid 1000, gid 1000: Operation not permitted"
#   for every file and exit true rc=2, even when sha256sum -c SHA256SUMS is
#   14/14 OK. Installers with set -e, and any operator reading the exit code,
#   conclude the release is broken. Parent A/B on real exfat:
#     plain tar xzf of uid-1000 tarball          → true rc=2
#     tar --no-same-owner -xzf (uid-1000 tarball) → true rc=0
#     plain tar xzf of --owner=0 --group=0 tarball → true rc=0
#   Fix is BUILD-time --owner=0 --group=0 --numeric-owner, not a doc workaround.
#
# Assertions (negatives a naive packager fails):
#   1. package_release.sh tar line carries --owner=0 --group=0 --numeric-owner
#   2. a tarball produced the same way as package_release has EVERY entry 0/0
#   3. a deliberately uid-1000 tarball is REJECTED by the same checker
#      (red-before-green / mutation visibility)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="$ROOT/scripts/package_release.sh"
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

[ -r "$PKG" ] || { echo "FAIL missing $PKG"; exit 1; }

# --- 1) structural: the packager must emit root-owned archives ---------------
# Match the real tar invocation window (not a comment-only mention).
tar_block=$(awk '
  /^tar -C / {grab=1}
  grab {print}
  grab && /-czf / {exit}
' "$PKG")
if printf '%s' "$tar_block" | grep -q -- '--owner=0' \
  && printf '%s' "$tar_block" | grep -q -- '--group=0' \
  && printf '%s' "$tar_block" | grep -q -- '--numeric-owner'; then
  pass "package_release tar carries --owner=0 --group=0 --numeric-owner"
else
  fail "package_release tar missing root-owner flags; block=[$tar_block]"
fi

# --- helper: assert every tar entry is 0/0 ----------------------------------
# GNU tar -tv: "drwxr-xr-x root/root ..." or "drwxr-xr-x 0/0 ..." with
# --numeric-owner. Reject any other user/group (e.g. flynnsbit/flynnsbit, 1000/1000).
assert_all_root_owner() {
  local tarpath=$1 label=$2
  local bad=0 total=0 line user
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    # field 2 is owner/group on GNU tar -tv
    user=$(printf '%s\n' "$line" | awk '{print $2}')
    case "$user" in
      0/0|root/root) ;;
      *)
        echo "  BAD_OWNER label=$label entry=$user line=$line"
        bad=$((bad + 1))
        ;;
    esac
  done < <(tar -tvzf "$tarpath" 2>/dev/null)
  echo "owner_scan label=$label total_entries=$total bad_entries=$bad"
  if [ "$total" -eq 0 ]; then
    echo "NO-DATA label=$label reason=empty_tar_listing"
    return 2
  fi
  if [ "$bad" -ne 0 ]; then
    return 1
  fi
  return 0
}

# --- 2) negative: uid-1000 tarball must FAIL the checker --------------------
mut_dir="$ROOT/build/unit-tar-owner-mut"
rm -rf "$mut_dir"
mkdir -p "$mut_dir/stage/bin"
printf 'payload\n' >"$mut_dir/stage/bin/dummy"
# Deliberately ship lab uid (current broken default without flags).
tar -C "$mut_dir" --transform='s|^stage|misterplex-mut|' \
  -czf "$mut_dir/bad.tar.gz" stage
set +e
assert_all_root_owner "$mut_dir/bad.tar.gz" uid1000_mut
neg_rc=$?
set -e
if [ "$neg_rc" -eq 1 ]; then
  pass "checker rejects uid≠0 tarball (red-before-green negative)"
else
  fail "checker must reject uid-1000 tarball (rc=$neg_rc)"
fi

# --- 3) positive: same tar flags as package_release → all 0/0 ---------------
# Build a tiny archive with the EXACT flag set the packager must use, so a
# regression that drops a flag fails here without a full release build.
good_dir="$ROOT/build/unit-tar-owner-good"
rm -rf "$good_dir"
mkdir -p "$good_dir/stage/bin" "$good_dir/stage/cores"
printf 'ok\n' >"$good_dir/stage/bin/misterplexd"
printf 'rbf\n' >"$good_dir/stage/cores/Plex.rbf"
tar -C "$good_dir" --transform='s|^stage|misterplex-good|' \
  --owner=0 --group=0 --numeric-owner \
  -czf "$good_dir/good.tar.gz" stage
set +e
assert_all_root_owner "$good_dir/good.tar.gz" root_flags
pos_rc=$?
set -e
if [ "$pos_rc" -eq 0 ]; then
  pass "root-owner flags produce all-0/0 entries"
else
  fail "root-owner flags still produced non-root entries (rc=$pos_rc)"
fi

# --- 4) tracked historical pair must NOT package (capability gate) ----------
# Parent 2026-08-02: e9f79de2 lacked delivery-geometry telemetry and regressed
# 480p on device. package_validated_pair must refuse (rc=7 CAPABILITY_FAIL),
# not produce a shippable tarball. Owner proof for the tar flags remains
# sections 1–3 (same flag set as package_release); do not re-enable shipping
# an incapable pin to exercise ownership.
PAIR="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2"
if [ -f "$PAIR/Plex.rbf" ] && [ -f "$PAIR/misterplexd" ] \
  && [ -x "$ROOT/scripts/package_validated_pair.sh" ]; then
  e2e_out="$ROOT/build/unit-tar-owner-e2e"
  rm -rf "$e2e_out"
  mkdir -p "$e2e_out"
  set +e
  OUT_DIR="$e2e_out" VERSION=tar-owner-e2e PACKAGE_ALLOW_NO_FFMPEG=1 \
    "$ROOT/scripts/package_validated_pair.sh" >"$e2e_out/pkg.log" 2>&1
  e2e_pkg_rc=$?
  set -e
  TAR_E2E="$e2e_out/misterplex-tar-owner-e2e.tar.gz"
  if [ "$e2e_pkg_rc" -eq 7 ] && grep -q 'CAPABILITY_FAIL\|capability/stamp' "$e2e_out/pkg.log" \
    && [ ! -f "$TAR_E2E" ]; then
    pass "package_validated_pair refuses incapable historical pair (rc=7, no tarball)"
  else
    fail "expected capability refuse rc=7 and no tarball; rc=$e2e_pkg_rc tar=$([ -f "$TAR_E2E" ] && echo yes || echo no)"
    sed -n '1,30p' "$e2e_out/pkg.log" || true
  fi
else
  echo "NOTE: skip historical-pair refuse check — tracked pair not present"
fi

rm -rf "$mut_dir" "$good_dir"

echo "applied_match_count=$applied"
if [ "$fails" -eq 0 ]; then
  echo "test_release_tar_owner: OK"
  exit 0
fi
echo "test_release_tar_owner: FAILED ($fails)"
exit 1
