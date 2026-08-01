#!/usr/bin/env bash
# Host-only unit for tools/analyze_mraudio_handoff.py
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/analyze_mraudio_handoff.py"
OUT="$ROOT/build/analyze_mraudio_handoff_unit"
mkdir -p "$OUT"
pass=0
fail=0

check_rc() {
  local name="$1" expect="$2" got="$3"
  if [[ "$got" -eq "$expect" ]]; then
    echo "PASS $name rc expect=$expect true_rc=$got"
    pass=$((pass + 1))
  else
    echo "FAIL $name rc expect=$expect true_rc=$got"
    fail=$((fail + 1))
  fi
}

set +e
python3 "$TOOL" --self-test >"$OUT/self.txt" 2>&1
src=$?
set -e
echo "CASE self-test true_rc=$src"
check_rc self_test 0 "$src"
if grep -q 'SELF_TEST_OK' "$OUT/self.txt"; then
  echo "PASS self_test banner"
  pass=$((pass + 1))
else
  echo "FAIL self_test banner"
  cat "$OUT/self.txt" | sed 's/^/  | /'
  fail=$((fail + 1))
fi

# Explicit pair files
cat >"$OUT/a.log" <<'EOF'
media: MrAudio handoff_at=audio_release mono_ms=1000 rptr=10000 wptr=29200 len_B=19200 len_ms=100 comp=0 frames_done=0 written_B=0 tag=measured
media: MrAudio handoff_at=first_video_present mono_ms=1080 rptr=12000 wptr=31200 len_B=19200 len_ms=100 comp=0 frames_done=1 written_B=3840 tag=measured
EOF
cat >"$OUT/b.log" <<'EOF'
media: MrAudio handoff_at=audio_release mono_ms=2000 rptr=32464 wptr=51664 len_B=19200 len_ms=100 comp=0 frames_done=0 written_B=0 tag=measured
media: MrAudio handoff_at=first_video_present mono_ms=2200 rptr=36000 wptr=55200 len_B=19200 len_ms=100 comp=0 frames_done=8 written_B=3840 tag=measured
EOF

set +e
python3 "$TOOL" --log-pair "$OUT/a.log" "$OUT/b.log" --json-out "$OUT/pair.json" >"$OUT/pair.txt" 2>&1
prc=$?
set -e
echo "CASE log-pair true_rc=$prc"
check_rc log_pair 0 "$prc"
if grep -q 'P_RPTR=SUPPORTED' "$OUT/pair.txt" && grep -q 'P_FDONE=SUPPORTED' "$OUT/pair.txt"; then
  echo "PASS pair verdicts"
  pass=$((pass + 1))
else
  echo "FAIL pair verdicts"
  sed 's/^/  | /' "$OUT/pair.txt"
  fail=$((fail + 1))
fi

# Empty → 77
set +e
python3 "$TOOL" --log-pair "$OUT/empty1.log" "$OUT/empty2.log" >"$OUT/empty.txt" 2>&1
erc=$?
set -e
# files missing → python exception; create empty files
: >"$OUT/empty1.log"
: >"$OUT/empty2.log"
set +e
python3 "$TOOL" --log-pair "$OUT/empty1.log" "$OUT/empty2.log" >"$OUT/empty.txt" 2>&1
erc=$?
set -e
echo "CASE empty true_rc=$erc"
check_rc empty 77 "$erc"

# Identical → 2
set +e
python3 "$TOOL" --log-pair "$OUT/a.log" "$OUT/a.log" >"$OUT/ident.txt" 2>&1
irc=$?
set -e
echo "CASE identical true_rc=$irc"
check_rc identical 2 "$irc"

echo "=== SUMMARY pass=$pass fail=$fail ==="
if [[ "$fail" -eq 0 ]]; then
  echo "ANALYZE_MRAUDIO_HANDOFF_OK pass=$pass"
  exit 0
fi
echo "ANALYZE_MRAUDIO_HANDOFF_FAIL"
exit 2
