#!/usr/bin/env bash
# Gate: packaged daemon must not lack capabilities present in current builds.
#
# OBSERVED DEFECT (parent hardware 2026-08-02): release pair daemon e9f79de2
# passed every host gate and rendered GREEN + duplicated TREK24 at 480p tier.
# Live daemon emitted measured=624x350 desync_risk=0. Capability gap, not conf.
#
# Assertions (capability/stamp — NOT hard-coded md5 equality of the two builds):
#   RED:  tracked release_artifacts daemon fails capability check
#   GREEN: current build/misterplexd passes capability (+ stamp when built)
#   RED:  synthetic binary missing one marker fails
#   GREEN: synthetic binary with all markers passes marker half
#   STRUCT: package_release.sh consults daemon_capability_check before tar
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$ROOT/scripts/daemon_capability_check.sh"
STAMP="$ROOT/scripts/daemon_stamp_check.sh"
PKG="$ROOT/scripts/package_release.sh"
PAIR_DAE="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd"
HOST_BIN="$ROOT/build/misterplexd"
fails=0
applied=0
pass() { echo "PASS $*"; applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

for f in "$CHK" "$STAMP" "$PKG"; do
  if [ -r "$f" ]; then
    pass "present $(basename "$f")"
  else
    fail "missing $f"
  fi
done

# --- RED: historical release daemon must FAIL capability (the shipped hole) ---
if [ -f "$PAIR_DAE" ]; then
  set +e
  out=$("$CHK" "$PAIR_DAE" 2>&1)
  rc=$?
  set -e
  echo "release_daemon_capability true rc=$rc"
  printf '%s\n' "$out" | head -20
  miss=$(printf '%s\n' "$out" | grep -c 'CAPABILITY_MARKER_MISSING' || true)
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'CAPABILITY_FAIL' && [ "$miss" -ge 1 ]; then
    pass "release artifact daemon FAILS capability (rc=$rc missing_markers=$miss) applied-match"
  else
    fail "release artifact daemon must CAPABILITY_FAIL; rc=$rc miss=$miss out=$out"
  fi
else
  fail "tracked release daemon missing at $PAIR_DAE"
fi

# --- GREEN: current host build must PASS capability ---
if [ ! -x "$HOST_BIN" ]; then
  echo "NOTE: building host misterplexd for capability GREEN"
  set +e
  make -C "$ROOT" "$HOST_BIN" >/dev/null 2>&1
  brc=$?
  set -e
  if [ "$brc" -ne 0 ] || [ ! -x "$HOST_BIN" ]; then
    fail "could not build $HOST_BIN (rc=$brc) — cannot prove GREEN path"
  fi
fi

if [ -x "$HOST_BIN" ]; then
  set +e
  out=$("$CHK" --require-stamp "$HOST_BIN" 2>&1)
  rc=$?
  set -e
  echo "host_daemon_capability true rc=$rc"
  printf '%s\n' "$out" | tail -15
  ok=$(printf '%s\n' "$out" | grep -c 'CAPABILITY_MARKER_OK' || true)
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'CAPABILITY_OK' && [ "$ok" -ge 4 ]; then
    pass "host build PASSES capability+stamp (rc=0 marker_ok=$ok) applied-match"
  else
    fail "host build must CAPABILITY_OK with stamp; rc=$rc ok=$ok out=$out"
  fi
fi

# --- RED: synthetic ELF-sized file missing markers ---
syn_bad="$ROOT/build/unit-cap-bad.bin"
mkdir -p "$ROOT/build"
# >1000 bytes so size check passes; no capability strings
python3 -c "from pathlib import Path; Path(r'''$syn_bad''').write_bytes(b'NOT_A_CAPABLE_DAEMON_'+b'x'*2000)"
set +e
out=$("$CHK" "$syn_bad" 2>&1)
rc=$?
set -e
rm -f "$syn_bad"
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'CAPABILITY_FAIL reason=missing_markers'; then
  pass "synthetic incapable binary FAILS (rc=$rc)"
else
  fail "synthetic incapable must rc=2 missing_markers; rc=$rc out=$out"
fi

# --- GREEN half of synthetic: plant all required markers ---
syn_ok="$ROOT/build/unit-cap-ok.bin"
python3 -c "
from pathlib import Path
markers = b'desync_risk= coded_bank= DELIVERY_MISMATCH_FINAL measured= padding'
Path(r'''$syn_ok''').write_bytes(markers * 50)
"
set +e
out=$("$CHK" "$syn_ok" 2>&1)
rc=$?
set -e
rm -f "$syn_ok"
# Without --require-stamp, markers alone => CAPABILITY_OK
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'CAPABILITY_OK'; then
  pass "synthetic with all markers PASSES marker check (rc=0)"
else
  fail "synthetic with markers must CAPABILITY_OK rc=0; rc=$rc out=$out"
fi

# --- STRUCT: package_release must consult capability check before tar ---
if grep -q 'daemon_capability_check.sh' "$PKG"; then
  pass "package_release.sh consults daemon_capability_check.sh"
else
  fail "package_release.sh does not consult daemon_capability_check.sh"
fi
cap_line=$(grep -n 'daemon_capability_check.sh' "$PKG" | head -1 | cut -d: -f1)
tar_line=$(grep -nE '^tar |tar -C' "$PKG" | head -1 | cut -d: -f1)
if [ -n "${cap_line:-}" ] && [ -n "${tar_line:-}" ] && [ "$cap_line" -lt "$tar_line" ]; then
  pass "capability gate (line $cap_line) runs before tar (line $tar_line)"
else
  fail "capability gate must precede tar (cap=${cap_line:-none} tar=${tar_line:-none})"
fi

# No env bypass for capability
if grep -qE '\$\{(CAPABILITY_[A-Z_]*(SKIP|FORCE|BYPASS|ALLOW)|SKIP_CAPABILITY|ALLOW_INCAPABLE)[A-Z_]*:?-' "$PKG"; then
  fail "package_release.sh exposes an environment bypass for capability gate"
else
  pass "capability gate has no environment bypass"
fi

# package_validated_pair must also refuse incapable historical pins for ship
PVP="$ROOT/scripts/package_validated_pair.sh"
if [ -r "$PVP" ] && grep -q 'daemon_capability_check.sh' "$PVP"; then
  pass "package_validated_pair.sh consults daemon_capability_check.sh"
else
  fail "package_validated_pair.sh must consult capability check (stop shipping e9f79de2-class)"
fi

echo "applied_match_count=$applied fails=$fails"
if [ "$fails" -eq 0 ]; then
  echo "test_release_not_older: OK"
  exit 0
fi
echo "test_release_not_older: FAILED ($fails)"
exit 1
