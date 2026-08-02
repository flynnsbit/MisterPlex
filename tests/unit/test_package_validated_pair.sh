#!/usr/bin/env bash
# Host unit: tracked stamped lab pair + package_validated_pair wiring.
#
# OBSERVED DEFECTS:
#   1) gitignored-only binaries blocked clean-clone ship (fixed by tracked pair).
#   2) parent HW 2026-08-02: default pin e9f79de2 regresses 480p (624x350 delivery;
#      green field + duplicated TREK24) and is unstamped — must not be default ship.
#
# Assertions (incl. negatives):
#   1. release_artifacts/ddr-c5382bee-509b0c75/{Plex.rbf,misterplexd,MANIFEST} exist
#   2. MANIFEST.md5 verifies
#   3. pair_ship_policy accepts stamped pair (PAIR_OK id=ddr-c5382bee-509b0c75)
#   4. daemon is STAMP_OK under --require-stamped (git_rev present)
#   5. capability markers present; historical e9f79de2 lacks them (negative)
#   6. package_validated_pair pins exact measured md5s + require-stamped (no allow-matrix)
#   7. PAIR_DIR at historical e9f79de2 is refused (negative — wrong default pin)
#   8. tampered core refused
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAIR="$ROOT/release_artifacts/ddr-c5382bee-509b0c75"
HIST="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2"
EXPECT_CORE=c5382bee73cecdee8220b811e529c297
EXPECT_DAEMON=509b0c7592e0e9e38686f9eb8e2cb047
EXPECT_CORE_BYTES=3970492
EXPECT_DAEMON_BYTES=13095524
EXPECT_STAMP=ba2ec3139133
HIST_DAEMON=e9f79de217982aff44207664fdb945c5
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

for f in "$PAIR/Plex.rbf" "$PAIR/misterplexd" "$PAIR/MANIFEST.md5" \
         "$ROOT/scripts/package_validated_pair.sh" "$ROOT/scripts/pair_ship_policy.sh" \
         "$ROOT/scripts/daemon_stamp_check.sh"; do
  if [ -e "$f" ]; then
    pass "present $(basename "$f")"
  else
    fail "missing $f"
  fi
done

if [ -f "$PAIR/MANIFEST.md5" ]; then
  set +e
  mout=$(cd "$PAIR" && md5sum -c MANIFEST.md5 2>&1)
  mrc=$?
  set -e
  if [ "$mrc" -eq 0 ]; then
    pass "MANIFEST.md5 verifies"
  else
    fail "MANIFEST.md5 failed rc=$mrc $mout"
  fi
fi

if [ -f "$PAIR/Plex.rbf" ]; then
  c_md5=$(md5sum "$PAIR/Plex.rbf" | awk '{print $1}')
  c_sz=$(wc -c <"$PAIR/Plex.rbf" | tr -d ' ')
  if [ "$c_md5" = "$EXPECT_CORE" ] && [ "$c_sz" = "$EXPECT_CORE_BYTES" ]; then
    pass "core md5+bytes match stamped pair ($c_sz)"
  else
    fail "core got md5=$c_md5 sz=$c_sz want $EXPECT_CORE / $EXPECT_CORE_BYTES"
  fi
fi

if [ -f "$PAIR/misterplexd" ]; then
  d_md5=$(md5sum "$PAIR/misterplexd" | awk '{print $1}')
  d_sz=$(wc -c <"$PAIR/misterplexd" | tr -d ' ')
  if [ "$d_md5" = "$EXPECT_DAEMON" ] && [ "$d_sz" = "$EXPECT_DAEMON_BYTES" ]; then
    pass "daemon md5+bytes match stamped pair ($d_sz)"
  else
    fail "daemon got md5=$d_md5 sz=$d_sz want $EXPECT_DAEMON / $EXPECT_DAEMON_BYTES"
  fi
fi

if [ -f "$PAIR/Plex.rbf" ] && [ -f "$PAIR/misterplexd" ]; then
  set +e
  pout=$("$ROOT/scripts/pair_ship_policy.sh" check "$EXPECT_CORE" "$EXPECT_DAEMON" 2>&1)
  prc=$?
  set -e
  if [ "$prc" -eq 0 ] && printf '%s' "$pout" | grep -q 'PAIR_OK' \
     && printf '%s' "$pout" | grep -q 'id=ddr-c5382bee-509b0c75'; then
    pass "pair_ship_policy PAIR_OK id=ddr-c5382bee-509b0c75"
  else
    fail "pair policy rc=$prc out=$pout"
  fi
fi

# Stamp: stamped pair must pass require-stamped; historical e9f must fail it.
if [ -f "$PAIR/misterplexd" ]; then
  set +e
  sout=$("$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$PAIR/misterplexd" 2>&1)
  src=$?
  set -e
  if [ "$src" -eq 0 ] && printf '%s' "$sout" | grep -q "git_rev=${EXPECT_STAMP}"; then
    pass "require-stamped STAMP_OK git_rev=${EXPECT_STAMP}"
  else
    fail "stamped pair require-stamped rc=$src out=$sout"
  fi
fi

if [ -f "$HIST/misterplexd" ]; then
  set +e
  hout=$("$ROOT/scripts/daemon_stamp_check.sh" --require-stamped "$HIST/misterplexd" 2>&1)
  hrc=$?
  set -e
  if [ "$hrc" -ne 0 ] && printf '%s' "$hout" | grep -q 'STAMP_FAIL'; then
    pass "require-stamped refuses historical e9f79de2 (rc=$hrc)"
  else
    fail "e9f79de2 must STAMP_FAIL under require-stamped rc=$hrc out=$hout"
  fi

  # Capability markers: stamped has them; e9f lacks desync_risk= (parent defect class).
  # grep -aF (not strings|grep -q) — pipefail+SIGPIPE falsely fails on match.
  if grep -aF -q -- 'desync_risk=' "$PAIR/misterplexd" \
     && grep -aF -q -- 'DELIVERY_MISMATCH measured=' "$PAIR/misterplexd"; then
    pass "stamped daemon has delivery-geometry capability markers"
  else
    fail "stamped daemon missing desync_risk=/DELIVERY_MISMATCH markers"
  fi
  if grep -aF -q -- 'desync_risk=' "$HIST/misterplexd"; then
    fail "historical e9f79de2 unexpectedly has desync_risk= (gate would be tautological)"
  else
    pass "historical e9f79de2 lacks desync_risk= (negative capability)"
  fi
else
  fail "historical pair missing at $HIST (needed for red-before-green capability contrast)"
fi

# Structural: package_validated_pair must pin new md5s and invoke require-stamped.
# Comments may mention --allow-matrix-pin as forbidden; only the live argv matters.
if grep -q -e "$EXPECT_DAEMON" "$ROOT/scripts/package_validated_pair.sh" \
   && grep -q -e 'ddr-c5382bee-509b0c75' "$ROOT/scripts/package_validated_pair.sh" \
   && grep -E -q 'daemon_stamp_check\.sh"[[:space:]]+--require-stamped' "$ROOT/scripts/package_validated_pair.sh" \
   && ! grep -E -q 'daemon_stamp_check\.sh"[[:space:]]+--allow-matrix-pin' "$ROOT/scripts/package_validated_pair.sh"; then
  pass "package_validated_pair pins stamped pair + require-stamped (no allow-matrix argv)"
else
  fail "package_validated_pair lost stamped pin / still allows matrix pin argv"
fi

# Negative: PAIR_DIR at historical e9f must not package as default path.
if [ -d "$HIST" ] && [ -f "$HIST/misterplexd" ]; then
  set +e
  out=$(PAIR_DIR="$HIST" PACKAGE_ALLOW_NO_FFMPEG=1 \
    "$ROOT/scripts/package_validated_pair.sh" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    pass "historical e9f PAIR_DIR refused (rc=$rc)"
  else
    fail "historical e9f must not package via package_validated_pair: $out"
  fi
fi

# Negative mutation: wrong core md5 refused.
mut="$ROOT/build/unit-pair-mutate"
rm -rf "$mut"
mkdir -p "$mut"
if [ -f "$PAIR/Plex.rbf" ] && [ -f "$PAIR/misterplexd" ]; then
  printf 'not-the-core' >"$mut/Plex.rbf"
  cp -a "$PAIR/misterplexd" "$mut/misterplexd"
  printf '%s  Plex.rbf\n%s  misterplexd\n' "$EXPECT_CORE" "$EXPECT_DAEMON" >"$mut/MANIFEST.md5"
  set +e
  out=$(PAIR_DIR="$mut" PACKAGE_ALLOW_NO_FFMPEG=1 \
    "$ROOT/scripts/package_validated_pair.sh" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    pass "tampered core refused (rc=$rc)"
  else
    fail "tampered core must not package: $out"
  fi
fi
rm -rf "$mut"

echo "applied_match_count=$applied"
if [ "$fails" -eq 0 ]; then
  echo "test_package_validated_pair: OK"
  exit 0
fi
echo "test_package_validated_pair: FAILED ($fails)"
exit 1
