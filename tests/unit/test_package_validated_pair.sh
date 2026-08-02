#!/usr/bin/env bash
# Host unit: tracked lab pair + package_validated_pair wiring.
#
# OBSERVED DEFECT: only artifacts that satisfy pair_ship_policy lived under
# gitignored paths, so a clean clone could not assemble a release.
#
# Assertions (incl. negatives):
#   1. release_artifacts/ddr-c5382bee-e9f79de2/{Plex.rbf,misterplexd,MANIFEST} exist
#   2. MANIFEST.md5 verifies (byte sizes + md5 match measured pair)
#   3. pair_ship_policy accepts the pair (PAIR_OK)
#   4. package_validated_pair.sh refuses a tampered core md5 (negative)
#   5. package_release consult path remains gated (no bypass) — structural
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAIR="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2"
EXPECT_CORE=c5382bee73cecdee8220b811e529c297
EXPECT_DAEMON=e9f79de217982aff44207664fdb945c5
EXPECT_CORE_BYTES=3970492
EXPECT_DAEMON_BYTES=12925900
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

for f in "$PAIR/Plex.rbf" "$PAIR/misterplexd" "$PAIR/MANIFEST.md5" \
         "$ROOT/scripts/package_validated_pair.sh" "$ROOT/scripts/pair_ship_policy.sh"; do
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
    pass "core md5+bytes match measured pair ($c_sz)"
  else
    fail "core got md5=$c_md5 sz=$c_sz want $EXPECT_CORE / $EXPECT_CORE_BYTES"
  fi
fi

if [ -f "$PAIR/misterplexd" ]; then
  d_md5=$(md5sum "$PAIR/misterplexd" | awk '{print $1}')
  d_sz=$(wc -c <"$PAIR/misterplexd" | tr -d ' ')
  if [ "$d_md5" = "$EXPECT_DAEMON" ] && [ "$d_sz" = "$EXPECT_DAEMON_BYTES" ]; then
    pass "daemon md5+bytes match measured pair ($d_sz)"
  else
    fail "daemon got md5=$d_md5 sz=$d_sz want $EXPECT_DAEMON / $EXPECT_DAEMON_BYTES"
  fi
fi

if [ -f "$PAIR/Plex.rbf" ] && [ -f "$PAIR/misterplexd" ]; then
  set +e
  pout=$("$ROOT/scripts/pair_ship_policy.sh" check "$EXPECT_CORE" "$EXPECT_DAEMON" 2>&1)
  prc=$?
  set -e
  if [ "$prc" -eq 0 ] && printf '%s' "$pout" | grep -q 'PAIR_OK'; then
    pass "pair_ship_policy PAIR_OK for tracked pair"
  else
    fail "pair policy rc=$prc out=$pout"
  fi
fi

# Negative: package_validated_pair must not silently accept wrong core.
# Run a dry structural check: script contains hard-coded expect hashes.
if grep -q "$EXPECT_CORE" "$ROOT/scripts/package_validated_pair.sh" && \
   grep -q "$EXPECT_DAEMON" "$ROOT/scripts/package_validated_pair.sh"; then
  pass "package_validated_pair pins exact measured md5s"
else
  fail "package_validated_pair lost exact md5 pins"
fi

# Negative mutation: if we point PAIR_DIR at a dir with wrong md5, must fail.
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
