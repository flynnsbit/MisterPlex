#!/usr/bin/env bash
# Host unit: scripts/daemon_stamp_check.sh
#
# OBSERVED DEFECT: live daemon md5 ea643e99 is not a git object
# (`git cat-file -t ea643e99` → Not a valid object name). Promotion must refuse
# untraceable binaries. Packaging may still ship historical matrix pins by md5
# via --allow-matrix-pin (e9f79de2).
#
# Negative cases a naive impl fails:
#   - empty/missing path treated as STAMP_OK
#   - binary without git_rev string treated as STAMP_OK under --require-stamped
#   - --allow-matrix-pin refuses the known matrix pin (blocks packaging)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$ROOT/scripts/daemon_stamp_check.sh"
HIST_DAE="$ROOT/release_artifacts/ddr-c5382bee-e9f79de2/misterplexd"
STAMP_DAE="$ROOT/release_artifacts/ddr-c5382bee-509b0c75/misterplexd"
HOST_BIN="$ROOT/build/misterplexd"
fails=0
applied=0
pass() { echo "PASS $*"; fails=$((fails)); applied=$((applied + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); applied=$((applied + 1)); }

[ -x "$CHK" ] || { echo "FAIL missing $CHK"; exit 1; }

# RED: missing file
set +e
out=$("$CHK" --require-stamped /no/such/misterplexd 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'missing_file\|STAMP_FAIL'; then
  pass "missing path hard-fails (rc=$rc)"
else
  fail "missing path should hard-fail, got rc=$rc out=$out"
fi

# RED: tiny garbage file is not a stamped daemon
garb="$ROOT/build/unit-stamp-garbage.bin"
mkdir -p "$ROOT/build"
printf 'not-an-elf' >"$garb"
set +e
out=$("$CHK" --require-stamped "$garb" 2>&1)
rc=$?
set -e
rm -f "$garb"
if [ "$rc" -ne 0 ]; then
  pass "tiny non-elf hard-fails (rc=$rc)"
else
  fail "tiny non-elf must not STAMP_OK: $out"
fi

# GREEN or documented matrix pin: historical e9f79de2 under allow-matrix-pin only
if [ -f "$HIST_DAE" ]; then
  set +e
  out=$("$CHK" --allow-matrix-pin "$HIST_DAE" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE 'MATRIX_PIN_OK|STAMP_OK'; then
    pass "allow-matrix-pin accepts historical e9f79de2 (rc=0)"
  else
    fail "allow-matrix-pin should accept historical pin rc=$rc out=$out"
  fi

  # RED-before-green: require-stamped must refuse unstamped historical pin
  set +e
  out=$("$CHK" --require-stamped "$HIST_DAE" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'STAMP_FAIL'; then
    pass "require-stamped refuses unstamped e9f79de2 (rc=$rc) applied-match"
  else
    fail "require-stamped must refuse unstamped pair daemon rc=$rc out=$out"
  fi
else
  fail "historical pair daemon missing at $HIST_DAE"
fi

# GREEN: default ship pin must be STAMP_OK under --require-stamped
if [ -f "$STAMP_DAE" ]; then
  set +e
  out=$("$CHK" --require-stamped "$STAMP_DAE" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'STAMP_OK' \
     && printf '%s' "$out" | grep -q 'git_rev=ba2ec3139133'; then
    pass "require-stamped STAMP_OK on 509b0c75 (git_rev=ba2ec3139133)"
  else
    fail "stamped ship pin must STAMP_OK rc=$rc out=$out"
  fi
else
  fail "stamped pair daemon missing at $STAMP_DAE (default ship path broken)"
fi

# GREEN: host build/misterplexd when present should be stamped
if [ -x "$HOST_BIN" ]; then
  set +e
  out=$("$CHK" --require-stamped "$HOST_BIN" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'STAMP_OK'; then
    pass "host build/misterplexd is STAMP_OK (rc=0)"
  else
    # Host binary may be x86; stamp string still required
    if printf '%s' "$out" | grep -q 'STAMP_FAIL reason=no_git_rev_string'; then
      fail "host misterplexd lacks git_rev string: $out"
    else
      fail "host stamp unexpected rc=$rc out=$out"
    fi
  fi
else
  echo "NOTE: skip host STAMP_OK — $HOST_BIN not built yet"
fi

echo "applied_match_count=$applied"
if [ "$fails" -eq 0 ]; then
  echo "test_daemon_stamp_check: OK"
  exit 0
fi
echo "test_daemon_stamp_check: FAILED ($fails)"
exit 1
